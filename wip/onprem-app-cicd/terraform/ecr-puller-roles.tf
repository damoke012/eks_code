# IRSA roles for `ecr-credentials-sync`, one per on-prem cluster.
#
# WHY THIS EXISTS
# ---------------
# infrastructure/ecr-credentials/rbac.yaml is byte-identical on the op-dev, op-qa
# and op-prod branches of iaac-talos-flux-platform, and all three annotate the
# ServiceAccount with the DEV role:
#
#   arn:aws:iam::700736442855:role/op-usxpress-dev-ecr-credentials-sync
#
# It was authored once for dev and copied. Only op-dev ever consumed the
# directory, so nothing surfaced. Wiring the Kustomization onto QA as-is would
# have QA's ServiceAccount present a token from QA's OWN OIDC provider while
# assuming a role that trusts dev's issuer: AssumeRoleWithWebIdentity fails, the
# CronJob exits non-zero, no ecr-pull-secret is ever written — and the Flux
# Kustomization still reports Ready=True, because applying a CronJob says nothing
# about whether it runs.
#
# Widening the dev role's trust policy to accept the QA and prod issuers would be
# one edit instead of three roles, but op-usxpress-prod/flux-system/infra.yaml
# states the opposite intent: "SELF-CONTAINED BY DESIGN ... own OIDC provider ...
# No cross-cluster bridge, no dependency on dev/QA accounts". A prod workload must
# not assume a dev-named role. Hence one role per cluster.
#
# ACCOUNT: 700736442855 (iaac-talos). The dev role already lives here, so this is
# the right home — unlike ecr-app-repos.tf, which targets 064859874041 and is
# still blocked on confirming which repo owns that account.
#
# ⚠️ DEPLOY VIA OCTOPUS ONLY. Never `terraform apply` iaac-talos locally, and
# check the Octopus deploy actually applied — TfApply=false is scoped (all) on
# every project except production, so a run prints the plan, skips the apply and
# still reports Success.

locals {
  # Clusters that need to pull from the shared ECR registry. op-usxpress-dev is
  # deliberately absent: its role already exists and is not managed here.
  ecr_puller_clusters = toset([
    "op-usxpress-qa",
    "op-usxpress-prod",
  ])

  shared_ecr_account = "064859874041"
}

# Each cluster's own OIDC provider. The URL shape must match how iaac-talos
# registers the provider for a Talos cluster — confirm against the existing dev
# provider before the PR, and replace this data lookup with whatever resource or
# remote-state output already holds it.
#
#   aws iam list-open-id-connect-providers
#
data "aws_iam_openid_connect_provider" "cluster" {
  for_each = local.ecr_puller_clusters

  url = var.cluster_oidc_issuer_urls[each.key]
}

resource "aws_iam_role" "ecr_credentials_sync" {
  for_each = local.ecr_puller_clusters

  name        = "${each.key}-ecr-credentials-sync"
  description = "Read-only pull from shared ECR ${local.shared_ecr_account} for ${each.key}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.cluster[each.key].arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          # Pinned to the one ServiceAccount that runs the CronJob. This identity
          # can write a secret into every namespace on the cluster, so the trust
          # policy is the only thing standing between it and any other workload.
          "${replace(data.aws_iam_openid_connect_provider.cluster[each.key].url, "https://", "")}:sub" = "system:serviceaccount:ecr-credentials:ecr-credentials-sync"
          "${replace(data.aws_iam_openid_connect_provider.cluster[each.key].url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Cluster  = each.key
    Platform = "on-prem"
    Purpose  = "ecr-pull"
  }
}

# Pull only. This role must never gain PutImage — pushing is the GitHub Actions
# identity's job (ecr-app-repos.tf), and keeping them separate means a compromised
# cluster cannot publish an image that the cluster would then trust.
resource "aws_iam_role_policy" "ecr_credentials_sync" {
  for_each = local.ecr_puller_clusters

  name = "ecr-pull"
  role = aws_iam_role.ecr_credentials_sync[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        # Scoped to the shared registry's repositories in both regions the
        # CronJob logs into (us-east-1 and us-east-2).
        Resource = [
          "arn:aws:ecr:us-east-1:${local.shared_ecr_account}:repository/*",
          "arn:aws:ecr:us-east-2:${local.shared_ecr_account}:repository/*",
        ]
      },
    ]
  })
}

variable "cluster_oidc_issuer_urls" {
  description = "OIDC issuer URL per on-prem cluster, as registered in IAM"
  type        = map(string)
  # Example — replace with the real values from:
  #   aws iam list-open-id-connect-providers
  # default = {
  #   "op-usxpress-qa"   = "https://oidc.op-usxpress-qa.example/..."
  #   "op-usxpress-prod" = "https://oidc.op-usxpress-prod.example/..."
  # }
}

output "ecr_puller_role_arns" {
  description = "ARN to annotate on each cluster's ecr-credentials-sync ServiceAccount"
  value       = { for k, r in aws_iam_role.ecr_credentials_sync : k => r.arn }
}

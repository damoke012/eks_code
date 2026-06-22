# Append to: iaac-talos/deploy/terraform/modules/irsa/main.tf
#
# IAM role for GitHub Actions running in usxpressinc/risingwave-poc to assume
# via OIDC and read RisingWave + Postgres secrets from AWS Secrets Manager.
#
# Use case (per Idris, 2026-05-18): Tim's repo runs workflows that connect to
# the Postgres metadata store and RisingWave Postgres for SQL pipeline work.
# Replaces the anti-pattern of storing DB creds as GitHub repo secrets.
#
# Trust:        scoped to master branch only (refs/heads/master)
# Permissions:  read-only on op-usxpress-dev/risingwave/* secrets
# Operator:     Tim Preble (via workflow_dispatch on usxpressinc/risingwave-poc)
#
# Cross-org note: trust principal points at usxpressinc (not variant-inc).
# GitHub's OIDC issuer is global — the condition just keys on the repo path.

# Look up the GitHub Actions OIDC provider. It is created by
# `github-actions-oidc-provider.tf` (sibling file in this same module).
# DO NOT create the provider here — single source of truth pattern.
data "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
  # depends_on ensures the resource lands before this data source reads.
  # Terraform usually handles this automatically when both files are in the
  # same apply, but the explicit dependency is cheap insurance.
  depends_on = [aws_iam_openid_connect_provider.github_actions]
}

resource "aws_iam_role" "gha_risingwave_poc_secrets" {
  name        = "gha-${var.cluster_name}-risingwave-poc-secrets"
  description = "GHA OIDC role for usxpressinc/risingwave-poc to read RW secrets from SM"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          # Standard audience claim for GitHub OIDC
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # Tight scope: only this repo's master branch. Blocks PRs from forks,
          # blocks any other branch in the repo, blocks any other repo.
          "token.actions.githubusercontent.com:sub" = "repo:usxpressinc/risingwave-poc:ref:refs/heads/master"
        }
      }
    }]
  })

  tags = {
    Cluster = var.cluster_name
    Purpose = "GHA-OIDC for risingwave-poc workflows reading SM secrets"
    Owner   = "tim-preble"
  }
}

# Read-only access scoped to the RisingWave secret namespace ONLY.
# DO NOT broaden to other prefixes without a separate review.
resource "aws_iam_role_policy" "gha_risingwave_poc_secrets" {
  name = "read-risingwave-secrets"
  role = aws_iam_role.gha_risingwave_poc_secrets.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadRisingWaveSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          # Wildcard at the end matches the AWS-suffixed ARN form
          # (op-usxpress-dev/risingwave/postgres-uscTgj, etc.)
          "arn:aws:secretsmanager:us-east-2:700736442855:secret:op-usxpress-dev/risingwave/*"
        ]
      },
      {
        Sid      = "ListSecretsMetadata"
        Effect   = "Allow"
        Action   = "secretsmanager:ListSecrets"
        Resource = "*"
      }
    ]
  })
}

# The GHA OIDC provider itself is created in the sibling file
# `github-actions-oidc-provider.tf`. Verified 2026-05-18 that no GHA OIDC
# provider existed in account 700736442855 — this account had only the on-prem
# Talos CloudFront provider and the EKS native provider. So the sibling file
# is the one that bootstraps the GHA OIDC trust for this entire account.

# GitHub Actions -> ECR push roles in 064859874041 (Infrastructure-Common).
#
# What these are for: a workflow in a named repo gets a short-lived AWS token because
# the role trusts that exact repo and ref. No secret is stored, rotated or leaked, and
# removing a repo's access is deleting an entry from `apps`.
#
# ⚠️ These three roles ALREADY EXIST and were created by hand. This file must be
#    IMPORTED onto them, never applied fresh: a second definition of a live role is how
#    a destroy removes the real one. See two-projects-one-resource.
#
#      terraform import 'aws_iam_role.ecr_push["risingwave-etl"]' gha-risingwave-etl-ecr-push
#      terraform import 'aws_iam_role.ecr_push["risingwave-poc"]' gha-risingwave-poc-ecr-push
#      terraform import 'aws_iam_role.ecr_push["sql-applier"]'    gha-sql-applier-ecr-push
#      terraform import 'aws_iam_role_policy.push["risingwave-etl"]' gha-risingwave-etl-ecr-push:ecr-push
#      terraform import 'aws_iam_role_policy.push["risingwave-poc"]' gha-risingwave-poc-ecr-push:ecr-push
#      terraform import 'aws_iam_role_policy.push["sql-applier"]'    gha-sql-applier-ecr-push:ecr-push
#
#    The map KEY renders the role name as gha-${key}-ecr-push, so the keys below are not
#    cosmetic — a key of "rw-poc" would create gha-rw-poc-ecr-push instead of importing
#    gha-risingwave-poc-ecr-push. Measured against the live roles 2026-10-16.
#
# ⚠️ The `sub` claim is an exact string match. An app repo that MOVES ORG stops
#    authenticating with no warning and no change on their side.

variable "apps" {
  description = "Each repo trusted to push, and the ECR repositories it may push to."
  type = map(object({
    github_org  = string
    github_repo = string
    ecr_repos   = list(string)
    refs        = list(string) # full git refs, e.g. refs/heads/master
    description = string
  }))

  # Measured from the live roles on 2026-10-16, not inferred from their descriptions:
  # gha-risingwave-etl-ecr-push's description claims "main branch only" while its trust
  # policy pins master. The policy is the truth; the description is corrected here, so
  # the first apply will show that change.
  default = {
    risingwave-etl = {
      github_org  = "variant-inc"
      github_repo = "risingwave-pipeline"
      ecr_repos   = ["risingwave/etl-pipeline", "risingwave/poc-pipeline"]
      refs        = ["refs/heads/master"]
      description = "GitHub Actions push to ECR. variant-inc/risingwave-pipeline, master only."
    }
    risingwave-poc = {
      github_org  = "usxpressinc"
      github_repo = "risingwave-poc"
      ecr_repos   = ["risingwave/poc-pipeline", "risingwave/sql-applier"]
      refs        = ["refs/heads/master"]
      description = "GitHub Actions: build the RW SQL pipeline image. usxpressinc/risingwave-poc, master only."
    }
    sql-applier = {
      github_org  = "variant-inc"
      github_repo = "iaac-risingwave-cicd"
      ecr_repos   = ["risingwave/sql-applier"]
      refs        = ["refs/heads/main"]
      description = "GitHub Actions: publish the SQL applier base image. variant-inc/iaac-risingwave-cicd, main only."
    }
  }
}

# ⚠️ KNOWN OVER-SCOPE, reproduced here DELIBERATELY so the import plan is clean.
#    Two roles reach an image they do not own:
#      risingwave-etl  -> poc-pipeline  (the image QA and dev actually run, owned by the poc repo)
#      risingwave-poc  -> sql-applier   (the base image every on-prem app build depends on)
#    So a bad build in either repo can overwrite the other's image. That contradicts the
#    one-repo-one-image intent. Tighten it as its OWN change after the import, where it
#    shows up as a reviewable diff instead of vanishing into a state operation.

variable "tags" {
  description = "Applied to every role. The roles currently carry NO tags at all."
  type        = map(string)
  default = {
    ManagedBy = "terraform"
    Component = "github-actions-ecr-push"
    Ticket    = "INFRA-1706"
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# One OIDC provider per account, created once. Reference it, never recreate it.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "assume" {
  for_each = var.apps

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringEquals, not StringLike: an exact ref, so a tag or another branch cannot assume.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        for r in each.value.refs :
        "repo:${each.value.github_org}/${each.value.github_repo}:ref:${r}"
      ]
    }
  }
}

resource "aws_iam_role" "ecr_push" {
  for_each = var.apps

  name                 = "gha-${each.key}-ecr-push"
  description          = each.value.description
  assume_role_policy   = data.aws_iam_policy_document.assume[each.key].json
  max_session_duration = 3600
  tags                 = var.tags
}

data "aws_iam_policy_document" "push" {
  for_each = var.apps

  # GetAuthorizationToken has no resource form, so it is "*" by necessity. It only
  # mints a registry login; the statement below is what bounds the actual push.
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [
      for r in each.value.ecr_repos :
      "arn:aws:ecr:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:repository/${r}"
    ]
  }
}

resource "aws_iam_role_policy" "push" {
  for_each = var.apps

  name   = "ecr-push"
  role   = aws_iam_role.ecr_push[each.key].id
  policy = data.aws_iam_policy_document.push[each.key].json
}

output "role_arns" {
  description = "Paste these into each repo's workflow as the role-to-assume."
  value       = { for k, r in aws_iam_role.ecr_push : k => r.arn }
}

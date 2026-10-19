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
    actions = concat([
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ], each.value.extra_actions)
    resources = [
      for r in each.value.ecr_repos :
      "arn:aws:ecr:${local.ecr_region}:${data.aws_caller_identity.current.account_id}:repository/${r}"
    ]
  }
}

resource "aws_iam_role_policy" "push" {
  for_each = var.apps

  name   = "ecr-push"
  role   = aws_iam_role.ecr_push[each.key].id
  policy = data.aws_iam_policy_document.push[each.key].json
}

# Trusting an app repo in ANOTHER GitHub org to push to one ECR repository.
#
# This is the whole cross-org credential story. The app team is never handed a
# secret; we add their repo to a trust policy on our side, and GitHub's OIDC
# token does the rest. Removing their access is deleting a line here.
#
# ⚠️ SET github_org / github_repo BEFORE APPLYING. The `sub` claim is an exact
#    string match -- an app repo that MOVES ORG stops authenticating, with no
#    warning and no config change on their side. That is the single most likely
#    failure of this design, and it is why the org question from the 2026-10-07
#    call has to be settled before this is applied, not after.

variable "apps" {
  description = "Each app repo trusted to push to its own ECR repository."
  type = map(object({
    github_org  = string # e.g. "variant-inc" or the USX org -- NOT guessed, confirmed
    github_repo = string
    ecr_repo    = string
    branches    = list(string)
  }))
  default = {}

  # ⚠️ These resources ALREADY EXIST in 064859874041 (measured 2026-10-07):
  #     ECR repo       risingwave/etl-pipeline
  #     IAM role       gha-risingwave-etl-ecr-push
  #     OIDC provider  token.actions.githubusercontent.com
  # So this file must be IMPORTED or reconciled against whatever already manages
  # them -- creating a second definition of the same role is how a destroy takes
  # out a live one. Find the owning repo before applying. See two-projects-one-resource.
  #
  # Confirmed 2026-10-07:
  #   rw-poc = {
  #     github_org  = "usxpressinc"
  #     github_repo = "risingwave-poc"
  #     ecr_repo    = "risingwave/etl-pipeline"
  #     branches    = ["master"]        # NOT main -- that repo defaults to master
  #   }
}

data "aws_caller_identity" "current" {}

# One OIDC provider per account, created once. Reference it, don't recreate it.
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

    # Pinned to repo + branch. Deliberately NOT pinned to `environment:` --
    # a sub containing environment:<name> only matches when the calling JOB
    # declares `environment:`, and a caller that omits it fails with a generic
    # "Not authorized to perform sts:AssumeRoleWithWebIdentity" that reads as a
    # permissions problem rather than a missing declaration. We have lost time
    # to that before. If an environment pin is ever wanted, the caller workflow
    # must be changed in the same PR.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        for b in each.value.branches :
        "repo:${each.value.github_org}/${each.value.github_repo}:ref:refs/heads/${b}"
      ]
    }
  }
}

resource "aws_iam_role" "ecr_push" {
  for_each = var.apps

  name               = "gha-${each.key}-ecr-push"
  description        = "GitHub Actions push for ${each.value.github_org}/${each.value.github_repo}"
  assume_role_policy = data.aws_iam_policy_document.assume[each.key].json
  max_session_duration = 3600
}

# Scoped to ONE repository. A compromised app pipeline cannot reach another
# app's images, and cannot delete anything.
data "aws_iam_policy_document" "push" {
  for_each = var.apps

  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action has no resource form
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
      "arn:aws:ecr:us-east-2:${data.aws_caller_identity.current.account_id}:repository/${each.value.ecr_repo}"
    ]
  }
}

resource "aws_iam_role_policy" "push" {
  for_each = var.apps

  name   = "ecr-push"
  role   = aws_iam_role.ecr_push[each.key].id
  policy = data.aws_iam_policy_document.push[each.key].json
}

output "push_role_arns" {
  description = "Paste the matching ARN into each app's caller workflow."
  value       = { for k, r in aws_iam_role.ecr_push : k => r.arn }
}

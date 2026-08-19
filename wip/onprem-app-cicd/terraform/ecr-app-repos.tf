# ECR repositories and GitHub OIDC push identities for on-prem applications.
#
# Onboarding an app is one entry in `locals.onprem_apps`. Everything else is
# generated: an immutable repository, a lifecycle policy, and a role that can push
# to that repository ONLY, from one GitHub repo, on one branch.
#
# ⚠️ TARGET REPO UNCONFIRMED. ECR is account 064859874041 (infra-common / devops).
# This does NOT belong in iaac-talos, which manages 700736442855. Confirm which
# IaC repo owns that account before raising the PR.

locals {
  # ------------------------------------------------------------------ onboard here
  onprem_apps = {
    "risingwave-etl" = {
      ecr_repository = "risingwave/etl-pipeline"
      github_repo    = "variant-inc/risingwave-pipeline"
      github_branch  = "main"
    }
  }
  # -----------------------------------------------------------------------------
}

resource "aws_ecr_repository" "onprem_app" {
  for_each = local.onprem_apps

  name                 = each.value.ecr_repository
  image_tag_mutability = "IMMUTABLE" # a tag cannot be moved once pushed

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Owner    = each.key
    Delivery = "argocd"
    Platform = "on-prem"
  }
}

resource "aws_ecr_lifecycle_policy" "onprem_app" {
  for_each   = local.onprem_apps
  repository = aws_ecr_repository.onprem_app[each.key].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "expire untagged after 7 days"
        selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 7 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "keep the most recent 50"
        selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 50 }
        action       = { type = "expire" }
      },
    ]
  })
}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# One push role per app. Trust pinned to a single repo AND branch — the same
# defence-in-depth as gha-op-usxpress-dev-risingwave-pipeline-secrets.
resource "aws_iam_role" "gha_ecr_push" {
  for_each = local.onprem_apps

  name = "gha-${each.key}-ecr-push"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${each.value.github_repo}:ref:refs/heads/${each.value.github_branch}"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "gha_ecr_push" {
  for_each = local.onprem_apps

  name = "ecr-push"
  role = aws_iam_role.gha_ecr_push[each.key].id

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
        # buildx reads the manifest back after pushing to confirm what it wrote,
        # so a pusher needs read on the same repository. Omitting these fails the
        # build AFTER every layer has uploaded, with a message that reads like a
        # push permission problem. Still scoped to the one repository.
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:DescribeImages",
        ]
        Resource = aws_ecr_repository.onprem_app[each.key].arn
      },
    ]
  })
}

output "onprem_app_push_roles" {
  description = "Role ARN each app's GitHub Actions workflow should assume"
  value       = { for k, r in aws_iam_role.gha_ecr_push : k => r.arn }
}

# ECR repository for the RisingWave ETL artefact, and the identity GitHub Actions
# assumes to push to it.
#
# ⚠️ TARGET REPO UNCONFIRMED. ECR lives in account 064859874041 (infra-common /
# devops). This file needs to land in whichever IaC repo manages that account —
# NOT iaac-talos, which manages 700736442855. Confirm before raising the PR.

resource "aws_ecr_repository" "risingwave_etl_pipeline" {
  name                 = "risingwave/etl-pipeline"
  image_tag_mutability = "IMMUTABLE" # a tag cannot be moved once pushed

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Owner    = "risingwave"
    Delivery = "argocd"
    Platform = "on-prem"
  }
}

# Keep the last 50 images; expire untagged after a week.
resource "aws_ecr_lifecycle_policy" "risingwave_etl_pipeline" {
  repository = aws_ecr_repository.risingwave_etl_pipeline.name
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

# Push identity. Trust is pinned to one repository AND one branch — the same
# defence-in-depth as gha-op-usxpress-dev-risingwave-pipeline-secrets.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_role" "gha_risingwave_etl_ecr_push" {
  name = "gha-risingwave-etl-pipeline-ecr-push"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:variant-inc/risingwave-pipeline:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "gha_risingwave_etl_ecr_push" {
  name = "ecr-push"
  role = aws_iam_role.gha_risingwave_etl_ecr_push.id

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
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        # scoped to this one repository — it cannot push anywhere else
        Resource = aws_ecr_repository.risingwave_etl_pipeline.arn
      },
    ]
  })
}

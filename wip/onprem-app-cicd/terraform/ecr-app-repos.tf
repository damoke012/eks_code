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
      github_branch  = "master"  # risingwave-pipeline's actual default branch
    }
    # Tim's own repo, in the OTHER GitHub org. It builds its SQL image itself and
    # the platform promotes the digest; see two-orgs-join-at-ecr-not-github.
    # Created by hand 2026-10-09, and its repository policy added the same night
    # after an on-prem pull 403'd on the manifest HEAD.
    "risingwave-poc" = {
      ecr_repository = "risingwave/poc-pipeline"
      github_repo    = "usxpressinc/risingwave-poc"
      github_branch  = "master"
    }
    # The applier base every SQL image is built FROM. It is published by
    # iaac-risingwave-cicd, not by an app, and nothing on-prem pulls it -- so it
    # gets a push role and NO cross-account pull policy.
    "sql-applier" = {
      ecr_repository = "risingwave/sql-applier"
      github_repo    = "variant-inc/iaac-risingwave-cicd"
      github_branch  = "main"
      pull_from_onprem = false
      # MUTABLE, unlike every other repository here. publish-applier pushes the
      # `latest` tag on every run, and an immutable repository refuses to move a
      # tag -- the push fails AFTER the build and the scan, with a message that
      # reads like a permissions problem. Measured on poc-pipeline 2026-10-09.
      tag_mutability = "MUTABLE"
    }
  }
  # -----------------------------------------------------------------------------
}

resource "aws_ecr_repository" "onprem_app" {
  for_each = local.onprem_apps

  name                 = each.value.ecr_repository
  # IMMUTABLE everywhere a digest is what gets deployed. The consequence is worth
  # knowing: because these builds tag by commit SHA, re-running a build on an
  # unchanged ref can never succeed, and a changed BASE image can never be
  # rebuilt onto an unchanged commit. That is the correct trade, not a defect.
  image_tag_mutability = lookup(each.value, "tag_mutability", "IMMUTABLE")

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Owner    = each.key
    Delivery = "argocd"
    Platform = "on-prem"
  }
}

# Cross-account pull for the three on-prem cluster accounts, and NOTHING else.
#
# Why this exists: a repository with no policy is unreadable from any other
# account, and the symptom is a kubelet `403 Forbidden` on the manifest HEAD —
# which reads like a broken pull secret. It is not. The pull secret authenticates
# to the REGISTRY; this authorises a specific repository. Cost us a full sync on
# 2026-08-20, and it is invisible until the first cross-account pull.
#
# Push needs no entry here: the GitHub OIDC role lives in 064859874041, the same
# account as the registry, so IAM alone covers it.
#
# ⚠️ Deliberately NOT modelled on the existing repositories. `lazy/api` grants
# PutImage, InitiateLayerUpload and CompleteLayerUpload to every principal in
# org o-yza5l1xhrc — so anything in the org can publish into it (INFRA-1643).
# This grants the three read actions, to three named accounts, and no write.
resource "aws_ecr_repository_policy" "onprem_app_pull" {
  # Only repositories an on-prem cluster actually pulls. The applier is built
  # FROM inside GitHub Actions, which is in the same account as the registry,
  # so granting three cluster accounts read on it would be scope for nothing.
  for_each = { for k, v in local.onprem_apps : k => v if lookup(v, "pull_from_onprem", true) }

  repository = aws_ecr_repository.onprem_app[each.key].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "OnPremClustersPullOnly"
      Effect = "Allow"
      Principal = {
        AWS = [
          "arn:aws:iam::700736442855:root", # op-usxpress-dev
          "arn:aws:iam::527101283767:root", # op-usxpress-qa
          "arn:aws:iam::937464026810:root", # op-usxpress-prod
        ]
      }
      Action = [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability",
      ]
    }]
  })
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

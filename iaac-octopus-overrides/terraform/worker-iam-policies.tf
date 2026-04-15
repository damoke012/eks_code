# IAM inline policies for the Octopus worker role (op-usxpress-dev).
#
# These policies give the worker the permissions needed to run MageRunner
# deployments to the on-prem Talos cluster. Applied to the existing role
# iaac-octopus-worker-op-usxpress-dev in account 786352483360 (Playground).
#
# Usage:
#   cd iaac-octopus-overrides/terraform
#   terraform init
#   terraform plan
#   terraform apply
#
# Cloud-safety: Only modifies the on-prem worker role in Playground account.
# No cloud IAM roles, policies, or accounts are touched.

terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket  = "dpl2-local-test-tfstate"
    key     = "onprem/worker-iam/terraform.tfstate"
    region  = "us-east-1"
    profile = "playground"
  }
}

provider "aws" {
  region  = "us-east-1"
  profile = "playground"
}

variable "worker_role_name" {
  default = "iaac-octopus-worker-op-usxpress-dev"
}

variable "cluster_name" {
  default = "op-usxpress-dev"
}

variable "state_bucket" {
  default = "dpl2-local-test-tfstate"
}

# SSM — read cluster parameters (endpoint, CA, token, OIDC issuer)
resource "aws_iam_role_policy" "ssm_cluster_params" {
  name = "ssm-cluster-params-read"
  role = var.worker_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ssm:GetParameter"]
      Resource = [
        "arn:aws:ssm:us-east-1:786352483360:parameter/clusters/${var.cluster_name}/*"
      ]
    }]
  })
}

# ECR — pull container images and Helm charts from devops account
# Cross-account access requires BOTH this identity policy AND a resource
# policy on the ECR repos in 064859874041 (already has org-wide allow).
resource "aws_iam_role_policy" "ecr_login" {
  name = "ecr-login"
  role = var.worker_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ecr:GetAuthorizationToken",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchCheckLayerAvailability",
        "ecr:ListImages",
        "ecr:DescribeImages",
        "ecr:DescribeRepositories",
      ]
      Resource = "*"
    }]
  })
}

# S3 — terraform state read/write
resource "aws_iam_role_policy" "s3_tfstate" {
  name = "s3-tfstate"
  role = var.worker_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket",
        "s3:DeleteObject",
      ]
      Resource = [
        "arn:aws:s3:::${var.state_bucket}",
        "arn:aws:s3:::${var.state_bucket}/*",
      ]
    }]
  })
}

# Secrets Manager — create/read/write app secrets (auth module, ExternalSecrets)
resource "aws_iam_role_policy" "secretsmanager_rw" {
  name = "secretsmanager-rw"
  role = var.worker_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:CreateSecret",
        "secretsmanager:GetSecretValue",
        "secretsmanager:PutSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:UpdateSecret",
        "secretsmanager:TagResource",
        "secretsmanager:GetResourcePolicy",
        "secretsmanager:PutResourcePolicy",
        "secretsmanager:DeleteResourcePolicy",
      ]
      Resource = "*"
    }]
  })
}

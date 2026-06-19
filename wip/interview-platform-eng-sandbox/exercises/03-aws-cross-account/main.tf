terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Two providers — one per account. Both use placeholders; this exercise is
# `terraform plan`-only against a sandbox role (no real apply).
provider "aws" {
  alias   = "account_a"
  region  = "us-east-1"
  profile = "interview-sandbox" # placeholder
}

provider "aws" {
  alias   = "account_b"
  region  = "us-east-1"
  profile = "interview-sandbox" # placeholder
}

variable "account_a_id" {
  type    = string
  default = "111111111111"
}

variable "account_b_id" {
  type    = string
  default = "222222222222"
}

# ----- ACCOUNT A: pod's source role (assumed via IRSA) -----
resource "aws_iam_role" "pod_source_role" {
  provider = aws.account_a
  name     = "demo-pod-secret-reader"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = "arn:aws:iam::${var.account_a_id}:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE"
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE:sub" = "system:serviceaccount:demo:demo-sa"
          "oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# TODO(junior): give the pod access to the cross-account secret.
# Couldn't get AssumeRole working in the dev sandbox, granted GetSecretValue
# directly for now. Plan succeeds — please review before we ship.
resource "aws_iam_role_policy" "pod_source_perms" {
  provider = aws.account_a
  role     = aws_iam_role.pod_source_role.id
  name     = "pod-secret-access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = "arn:aws:secretsmanager:us-east-1:${var.account_b_id}:secret:demo-app/db-creds-*"
    }]
  })
}

# ----- ACCOUNT B: target role that should be assumed cross-account -----
resource "aws_iam_role" "cross_account_reader" {
  provider = aws.account_b
  name     = "cross-account-secret-reader"

  # TODO: open during dev so I could test the chain end-to-end.
  # Need to lock down before this goes anywhere near prod.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        AWS = "*"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "cross_account_reader_perms" {
  provider = aws.account_b
  role     = aws_iam_role.cross_account_reader.id
  name     = "read-demo-secret"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = "arn:aws:secretsmanager:us-east-1:${var.account_b_id}:secret:demo-app/db-creds-*"
    }]
  })
}

# (the secret itself is provisioned elsewhere — assume it exists in B)

# Append to: iaac-talos/deploy/terraform/modules/irsa/main.tf
# (Or, preferred: create a new file `github-actions-oidc-provider.tf` in the
# same module directory — one resource per file for discoverability.)
#
# Creates the account-level OIDC trust to GitHub Actions in account 700736442855.
# This is a ONE-TIME, ACCOUNT-WIDE resource. Once created, any number of IAM
# roles in this account can declare GHA trust via:
#
#   data "aws_iam_openid_connect_provider" "github_actions" {
#     url = "https://token.actions.githubusercontent.com"
#   }
#
# Verified 2026-05-18 via `aws iam list-open-id-connect-providers --profile usx-dev`:
# only `cloudfront.net` (Talos IRSA) and `oidc.eks.us-east-2.amazonaws.com`
# (EKS native) exist. No GHA provider — this resource creates it.
#
# If a future engineer accidentally tries to create this twice, terraform will
# fail with "EntityAlreadyExists". Solution: remove the duplicate block; the
# data source above continues to work.

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  # Modern AWS validates the X.509 chain to GitHub directly; the thumbprint
  # field is effectively vestigial. An all-zeros placeholder is the common
  # convention (avoids worrying about cert rotation invalidating us).
  thumbprint_list = ["0000000000000000000000000000000000000000"]

  tags = {
    Cluster = var.cluster_name
    Purpose = "GitHub Actions OIDC federation (account-wide)"
  }
}

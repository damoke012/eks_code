# GitHub Actions OIDC provider — account-wide bootstrap
#
# REUSABLE. Drop this exact file into the Terraform module that manages IAM
# for whichever AWS account needs GHA→AWS federation. The resource is
# account-scoped: each AWS account needs its OWN copy applied once.
#
# WHY YOU MIGHT NEED THIS:
#   - You're adding a GitHub Actions workflow that needs to read AWS resources
#     (Secrets Manager, S3, etc.) in account X
#   - Account X doesn't have the GHA OIDC provider yet
#   - Then a per-use-case IAM role uses `data.aws_iam_openid_connect_provider`
#     to reference this and scopes trust to specific repo/branch via :sub claim
#
# CHECK BEFORE APPLYING (read-only, no risk):
#   aws iam list-open-id-connect-providers --profile <profile>
#   Look for an ARN ending in `/token.actions.githubusercontent.com`
#   If present → DO NOT add this resource. Use `data` source to reference it.
#   If absent  → add this resource. Apply once.

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  # Modern AWS validates the X.509 chain directly to GitHub's issuer cert; the
  # thumbprint field is effectively vestigial. All-zeros is the standard
  # convention to avoid cert-rotation churn.
  thumbprint_list = ["0000000000000000000000000000000000000000"]

  tags = {
    Purpose   = "GitHub Actions OIDC federation (account-wide)"
    ManagedBy = "terraform"
  }
}

output "github_actions_oidc_provider_arn" {
  description = "ARN of the GHA OIDC provider — use in IAM role trust policies"
  value       = aws_iam_openid_connect_provider.github_actions.arn
}

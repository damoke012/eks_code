# Append to: iaac-talos/deploy/terraform/modules/irsa/outputs.tf

output "gha_risingwave_poc_secrets_role_arn" {
  description = "ARN of the GHA OIDC role used by usxpressinc/risingwave-poc to read SM secrets"
  value       = aws_iam_role.gha_risingwave_poc_secrets.arn
}

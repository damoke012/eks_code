# Split out of main.tf for tflint's terraform_standard_module_structure rule.

output "role_arns" {
  description = "Paste these into each repo's workflow as the role-to-assume."
  value       = { for k, r in aws_iam_role.ecr_push : k => r.arn }
}

# Append to: iaac-talos/deploy/terraform/modules/irsa/outputs.tf

output "extd_usxpress_io_role_arn" {
  description = "ARN of the on-prem external-dns source IAM role (chains into iaac-route53-zone in 155768531003)"
  value       = aws_iam_role.extd_usxpress_io.arn
}

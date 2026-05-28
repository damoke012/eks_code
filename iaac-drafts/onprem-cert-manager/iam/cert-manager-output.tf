# Append to: iaac-talos/deploy/terraform/modules/irsa/outputs.tf

output "cert_manager_role_arn" {
  description = "ARN of the on-prem cert-manager source IAM role (chains into iaac-route53-zone for DNS-01 ACME challenges)"
  value       = aws_iam_role.cert_manager.arn
}

# talosconfig-secret.tf
#
# Codifies the manual `aws secretsmanager create-secret` ceremony that
# seeds the talosconfig for the etcd-backup CronJob's ExternalSecret.
#
# IMPORTANT — value handling:
#   The secret VALUE (the talosconfig YAML) is provisioned out-of-band the
#   first time, via the operator running:
#     aws secretsmanager create-secret \
#       --name <cluster>/talosconfig \
#       --secret-string file:///path/to/talosconfig
#
#   This Terraform resource creates the secret WRAPPER (name, description,
#   tags, KMS policy) and uses `lifecycle.ignore_changes = [secret_string]`
#   so future Terraform applies don't overwrite the operator-seeded value.
#
#   Rationale: the talosconfig contains x509 client cert+key extracted from
#   tfstate. We don't want it logged in Terraform plan output (even with
#   sensitive=true, the value would be base64-encoded in state). Better to
#   declare the WRAPPER in IaC and seed VALUES via the operator runbook.
#
# Recovery: if the secret is deleted or value drifts, re-seed via the same
# CLI command. The Terraform-managed wrapper will adopt it on next apply.
#
# Refs: INFRA-1541, AWS SM seed step in onprem-safety Rule 6.

resource "aws_secretsmanager_secret" "talosconfig" {
  name        = "${var.cluster_name}/talosconfig"
  description = "Talosconfig for ${var.cluster_name} cluster — used by etcd-backup CronJob ExternalSecret to authenticate talosctl etcd snapshot. Source of truth: tfstate (recovery path in onprem-safety skill Rule 6)."

  recovery_window_in_days = 7

  tags = {
    Cluster = var.cluster_name
    Purpose = "etcd-backup"
    Owner   = "on-prem-platform"
  }
}

# The placeholder value avoids "secret has no version" errors when Terraform
# first creates the wrapper. The operator overrides it with the real talosconfig
# via `aws secretsmanager put-secret-value` (or create-secret on initial seed).
#
# After first apply, the operator runs:
#   aws secretsmanager put-secret-value \
#     --secret-id <cluster>/talosconfig \
#     --secret-string file://~/.talos/config-<cluster>
#
# Future Terraform applies ignore the secret_string drift.
resource "aws_secretsmanager_secret_version" "talosconfig_placeholder" {
  secret_id     = aws_secretsmanager_secret.talosconfig.id
  secret_string = jsonencode({
    placeholder = "Seed the real talosconfig via 'aws secretsmanager put-secret-value' — see talosconfig-secret.tf docstring."
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

output "talosconfig_secret_arn" {
  description = "ARN of the talosconfig AWS Secrets Manager secret"
  value       = aws_secretsmanager_secret.talosconfig.arn
}

output "talosconfig_secret_name" {
  description = "Name of the talosconfig AWS Secrets Manager secret (matches ExternalSecret.spec.data[0].remoteRef.key)"
  value       = aws_secretsmanager_secret.talosconfig.name
}

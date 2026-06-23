# Append these to deploy/terraform/modules/irsa/outputs.tf
# (NOT a standalone file — content for git diff / append only)


output "velero_role_arn" {
  description = "ARN of the Velero IRSA role"
  value       = aws_iam_role.velero.arn
}

output "velero_bucket_name" {
  description = "S3 bucket name for Velero backups"
  value       = aws_s3_bucket.velero.id
}

output "etcd_backup_role_arn" {
  description = "ARN of the etcd snapshot IRSA role"
  value       = aws_iam_role.etcd_backup.arn
}

output "etcd_snapshots_bucket_name" {
  description = "S3 bucket name for Talos etcd snapshots"
  value       = aws_s3_bucket.etcd_snapshots.id
}

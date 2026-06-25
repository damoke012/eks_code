output "source_bucket" {
  description = "Existing TF state bucket (us-east-2)"
  value       = data.aws_s3_bucket.source.id
}

output "destination_bucket" {
  description = "New replica bucket (us-west-2)"
  value       = aws_s3_bucket.destination.id
}

output "replication_role_arn" {
  description = "IAM role used by S3 for CRR"
  value       = aws_iam_role.replication.arn
}

output "verification_commands" {
  description = "Commands to confirm CRR is live"
  value       = <<-EOT
    aws --profile usx-dev s3api get-bucket-replication --bucket ${var.source_bucket_name}
    aws --profile usx-dev s3api get-bucket-versioning  --bucket ${var.source_bucket_name}
    aws --profile usx-dev --region ${var.destination_region} s3api get-bucket-versioning --bucket ${var.destination_bucket_name}
  EOT
}

output "state_bucket_name" {
  description = "Primary state bucket name — feed this to iaac-talos backend config"
  value       = aws_s3_bucket.source.id
}

output "state_bucket_arn" {
  value = aws_s3_bucket.source.arn
}

output "replica_bucket_name" {
  description = "CRR replica bucket in us-west-2"
  value       = aws_s3_bucket.destination.id
}

output "dynamodb_lock_table_name" {
  description = "Lock table name — feed this to iaac-talos backend config"
  value       = aws_dynamodb_table.tf_lock.name
}

output "source_kms_key_arn" {
  value = aws_kms_key.source.arn
}

output "replica_kms_key_arn" {
  value = aws_kms_key.replica.arn
}

output "backend_config_snippet" {
  description = "Paste-ready -backend-config args for iaac-talos QA branch"
  value       = <<-EOT
    terraform init \
      -backend-config="bucket=${aws_s3_bucket.source.id}" \
      -backend-config="key=iaac/talos/op-usxpress-qa.tfstate" \
      -backend-config="region=us-east-2" \
      -backend-config="dynamodb_table=${aws_dynamodb_table.tf_lock.name}" \
      -backend-config="encrypt=true" \
      -backend-config="kms_key_id=${aws_kms_key.source.arn}"
  EOT
}

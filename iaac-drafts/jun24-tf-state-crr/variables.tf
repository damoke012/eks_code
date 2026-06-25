variable "source_bucket_name" {
  description = "Existing on-prem Talos TF state bucket (us-east-2)"
  type        = string
  default     = "lazy-tf-state-65v583i6my68y6x9"
}

variable "destination_bucket_name" {
  description = "Sibling bucket in us-west-2 to receive replicas"
  type        = string
  default     = "lazy-tf-state-65v583i6my68y6x9-replica"
}

variable "destination_region" {
  description = "Replica region"
  type        = string
  default     = "us-west-2"
}

variable "source_kms_key_arn" {
  description = "ARN of the KMS key the source bucket uses for SSE-KMS (alias/aws/s3 default resolves to a specific key per account)"
  type        = string
  default     = "arn:aws:kms:us-east-2:700736442855:key/c1f3cd42-f77f-43a1-b2e4-b45dd6783ee0"
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default = {
    ManagedBy = "Terraform"
    Purpose   = "on-prem-talos-tfstate-DR"
    Ticket    = "INFRA-1557"
  }
}

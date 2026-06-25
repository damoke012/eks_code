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

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default = {
    ManagedBy = "Terraform"
    Purpose   = "on-prem-talos-tfstate-DR"
    Ticket    = "INFRA-1557"
  }
}

variable "source_bucket_name" {
  description = "The primary S3 state bucket in USX-QA (us-east-2). Convention: lazy-tf-state-usx-qa."
  type        = string
  default     = "lazy-tf-state-usx-qa"
}

variable "destination_bucket_name" {
  description = "The CRR replica bucket in us-west-2. Same account, different region."
  type        = string
  default     = "lazy-tf-state-usx-qa-replica"
}

variable "dynamodb_table_name" {
  description = "State locking table (us-east-2). One table can lock multiple state files."
  type        = string
  default     = "lazy-tf-state-usx-qa-lock"
}

variable "tags" {
  description = "Extra tags applied on top of default_tags."
  type        = map(string)
  default = {
    ManagedByRepo = "damoke012/eks_code (wip/qa-cluster-standup/tf-state-usx-qa)"
  }
}

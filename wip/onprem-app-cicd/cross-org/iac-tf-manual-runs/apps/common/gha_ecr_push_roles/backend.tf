terraform {
  backend "s3" {
    bucket         = "lazy-tf-state-80a9de7d7f07"
    key            = "DevOps/iac-tf-manual-runs/gha_ecr_push_roles/terraform.tfstate"
    region         = "us-east-2"
    dynamodb_table = "lazy_tf_state"
    encrypt        = true
  }
}

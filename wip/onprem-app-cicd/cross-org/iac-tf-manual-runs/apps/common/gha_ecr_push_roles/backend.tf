terraform {
  required_version = ">= 1.6"

  # The provider version IS the pin here: this repo gitignores
  # .terraform.lock.hcl, so without a constraint every fresh init takes whatever
  # is newest that day. A major bump can add an API call the deploy role was never
  # granted, which fails at READ with nothing applied. State was built on 6.69.1.
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
  }

  backend "s3" {
    bucket         = "lazy-tf-state-80a9de7d7f07"
    key            = "DevOps/iac-tf-manual-runs/gha_ecr_push_roles/terraform.tfstate"
    region         = "us-east-2"
    dynamodb_table = "lazy_tf_state"
    encrypt        = true
  }
}

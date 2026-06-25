terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  alias  = "source"
  region = "us-east-2"
}

provider "aws" {
  alias  = "destination"
  region = "us-west-2"
}

terraform {
  required_version = ">= 1.5"
  required_providers {
    octopusdeploy = {
      source  = "OctopusDeployLabs/octopusdeploy"
      version = ">= 0.30, < 1.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.27"
    }
  }
}

provider "octopusdeploy" {
  address = "https://octopus.knight-swift.com"
  api_key = var.octopus_api_key
}

provider "aws" {
  region  = "us-east-1"
  profile = "playground"
}

provider "kubernetes" {
  config_path    = "~/.kube/op-usxpress-dev.yaml"
  config_context = "op-usxpress-dev"
}

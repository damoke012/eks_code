# Region is pinned rather than inherited from the environment: the ECR repositories
# these roles reach are in us-east-2, and the resource ARNs are built from it. An
# operator running with AWS_REGION=us-east-1 would otherwise produce a plan that
# rewrites every policy to point at repositories that do not exist there.
provider "aws" {
  region = "us-east-2"

  default_tags {
    tags = merge(
      {
        team        = "cloudops"
        purpose     = "GitHub Actions OIDC roles that push the RisingWave ECR images"
        owner       = "github"
        Name        = "gha_ecr_push_roles"
        project     = "iac-tf-manual-runs"
        environment = "Infrastructure-Common"
        group       = "github-actions"
      }
    )
  }
}

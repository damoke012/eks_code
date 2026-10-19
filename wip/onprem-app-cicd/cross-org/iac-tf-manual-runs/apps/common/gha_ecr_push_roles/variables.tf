# Split out of main.tf for tflint's terraform_standard_module_structure rule.

variable "apps" {
  description = "Each repo trusted to push, and the ECR repositories it may push to."
  type = map(object({
    github_org  = string
    github_repo = string
    ecr_repos   = list(string)
    extra_actions = list(string)
    refs        = list(string) # full git refs, e.g. refs/heads/master
    description = string
  }))

  # Measured from the live roles on 2026-10-16, not inferred from their descriptions:
  # gha-risingwave-etl-ecr-push's description claims "main branch only" while its trust
  # policy pins master. The policy is the truth; the description is corrected here, so
  # the first apply will show that change.
  default = {
    risingwave-etl = {
      github_org  = "variant-inc"
      github_repo = "risingwave-pipeline"
      ecr_repos   = ["risingwave/etl-pipeline", "risingwave/poc-pipeline"]
      refs        = ["refs/heads/master"]
      # Live policy carries these two and the others do not. Reproduced as found;
      # whether this role needs to read images is a question for the tightening pass.
      extra_actions = ["ecr:DescribeImages", "ecr:ListImages"]
      description   = "GitHub Actions push to ECR. variant-inc/risingwave-pipeline, master only."
    }
    risingwave-poc = {
      github_org  = "usxpressinc"
      github_repo = "risingwave-poc"
      ecr_repos   = ["risingwave/poc-pipeline", "risingwave/sql-applier"]
      refs          = ["refs/heads/master"]
      extra_actions = []
      description   = "GitHub Actions: build the RW SQL pipeline image. usxpressinc/risingwave-poc, master only."
    }
    sql-applier = {
      github_org  = "variant-inc"
      github_repo = "iaac-risingwave-cicd"
      ecr_repos   = ["risingwave/sql-applier"]
      refs          = ["refs/heads/main"]
      extra_actions = []
      description   = "GitHub Actions: publish the SQL applier base image. variant-inc/iaac-risingwave-cicd, main only."
    }
  }
}

# ⚠️ KNOWN OVER-SCOPE, reproduced here DELIBERATELY so the import plan is clean.
#    Two roles reach an image they do not own:
#      risingwave-etl  -> poc-pipeline  (the image QA and dev actually run, owned by the poc repo)
#      risingwave-poc  -> sql-applier   (the base image every on-prem app build depends on)
#    So a bad build in either repo can overwrite the other's image. That contradicts the
#    one-repo-one-image intent. Tighten it as its OWN change after the import, where it
#    shows up as a reviewable diff instead of vanishing into a state operation.

data "aws_caller_identity" "current" {}
locals {
  ecr_region = "us-east-2"
}

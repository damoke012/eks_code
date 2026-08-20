# Adopt what already exists, rather than recreating it.
#
# `risingwave/etl-pipeline` and its policy were created by hand on 2026-08-18 and
# 2026-08-20, because the IaC repo that owns account 064859874041 had not been
# identified and the work was blocking. That was a stopgap and it produced drift:
# two live resources nothing describes.
#
# These import blocks (Terraform >= 1.5) bind the existing objects to state on the
# next apply. `terraform plan` must then show **no changes** for them — if it wants
# to replace the repository, STOP: replacing an ECR repository deletes every image
# in it, including the digest QA is currently running.
#
# Verify before merging:
#   terraform plan -target=aws_ecr_repository.onprem_app -target=aws_ecr_repository_policy.onprem_app_pull
#   → "0 to add, 0 to change, 0 to destroy" is the only acceptable result.

import {
  to = aws_ecr_repository.onprem_app["risingwave-etl"]
  id = "risingwave/etl-pipeline"
}

import {
  to = aws_ecr_repository_policy.onprem_app_pull["risingwave-etl"]
  id = "risingwave/etl-pipeline"
}

# The GitHub OIDC push role, also created by hand.
# Confirm the exact role name before uncommenting — if it differs from what
# ecr-app-repos.tf generates, fix the generated name to match the live one rather
# than renaming a role that GitHub Actions currently authenticates as.
#
# import {
#   to = aws_iam_role.onprem_app_push["risingwave-etl"]
#   id = "gha-risingwave-etl-ecr-push"
# }

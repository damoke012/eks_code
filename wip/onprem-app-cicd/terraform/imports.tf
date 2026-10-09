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

# ---------------------------------------------------------------------------
# Added 2026-10-09. Three more live objects created by hand, for the same
# reason: the IaC repo that owns account 064859874041 is still unidentified and
# the work was blocking.
#
# ⚠️ Check the plan for image_tag_mutability on EVERY repository before applying.
# risingwave/poc-pipeline is IMMUTABLE live (proven 2026-10-09 by a push that
# failed trying to move a commit-SHA tag). risingwave/sql-applier MUST stay
# MUTABLE because publish-applier moves `latest`. If the plan wants to change
# mutability on either, STOP -- flipping sql-applier to IMMUTABLE breaks the
# applier publish, and flipping anything else is a deliberate decision, not a
# tidy-up.

import {
  to = aws_ecr_repository.onprem_app["risingwave-poc"]
  id = "risingwave/poc-pipeline"
}

import {
  to = aws_ecr_repository_policy.onprem_app_pull["risingwave-poc"]
  id = "risingwave/poc-pipeline"
}

import {
  to = aws_ecr_repository.onprem_app["sql-applier"]
  id = "risingwave/sql-applier"
}

# The hand-made ecr-push policy addition on 2026-10-09 is NOT imported here: it
# was a statement added to an existing role's inline policy, so the role must be
# identified first. Importing a role whose live inline policy differs from what
# ecr-app-repos.tf generates REPLACES that policy on apply -- which is how one
# account's second cluster de-authorised the first. Confirm the live role name
# and its current policy document before adding an import for it.

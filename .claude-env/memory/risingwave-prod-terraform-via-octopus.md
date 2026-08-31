---
name: risingwave-prod-terraform-via-octopus
description: iaac-risingwave-onprem's Terraform is environment-generic and parameterised entirely by Octopus variables — no tfvars, no backend files; and a skipped apply still reports Success
metadata:
  type: project
---

`variant-inc/iaac-risingwave-onprem` builds the RisingWave S3 bucket, IRSA role and five
of the six Secrets Manager entries from `deploy/terraform/`. It is environment-generic:
every input is a variable and the S3 backend block is deliberately empty so a missing
`-backend-config` fails loudly instead of landing in another environment's state.

There are **no committed tfvars and no `backend-*.hcl`**. `deploy/deploy.ps1`, run by
Octopus, exports every `TF_VAR_*` Octopus variable as an env var and takes the backend
from `S3_BUCKET` / `TF_STATE_KEY` / `AWS_DEFAULT_REGION`. Adding an environment is an
Octopus environment + variable scope.

Prod values: `TF_VAR_cluster_name=op-usxpress-prod`, `TF_VAR_oidc_issuer=d3rxit8f4yvshu`,
`TF_VAR_s3_bucket_prefix=risingwave-state-op-usxpress-prod`, account 937464026810.
Names derive as `sm_prefix = "${var.cluster_name}/risingwave"` and IRSA role
`"${var.cluster_name}-risingwave"`.

**`dex_entra_client_secret` is NOT in Terraform** — hand-created, and it depends on the
prod Entra app registration, which puts that request on the critical path.

**Why:** two traps. `apply` is gated on `TfApply` (`deploy.ps1:76`); when it is not
`"true"` the script prints "plan only, no apply" and the deploy **still reports Success** —
the same shape as [[octopus-green-but-no-apply]]. And `deploy/terraform/s3.tf` is an
**empty 0-line file**; the bucket lives in `main.tf:31-56`, so grepping s3.tf proves
nothing.

**How to apply:** proof that an apply actually ran is `terraform_outputs.yml` attached as
an Octopus artifact — `deploy.ps1:80-86` writes it only on the apply branch. Green with no
artifact means nothing was created. Before deploying, check
[[terraform-import-blocks-block-new-envs]].

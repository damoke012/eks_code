---
name: terraform-state-bucket-is-per-account
description: Each environment's Terraform state lives in its OWN account's lazy-tf-state-* bucket; a copied backend bucket fails 403 on first state read, not at init
metadata:
  type: project
---

Terraform state buckets are **per account**, and the account is not in the name:

| Env | Account | State bucket |
|---|---|---|
| cloud dev / op-dev | 700736442855 | `lazy-tf-state-65v583i6my68y6x9` |
| QA / op-usxpress-qa | 527101283767 | `lazy-tf-state-425rbol87rmn6c7m` (also `lazy-tf-state-usx-qa`) |
| prod / op-usxpress-prod | 937464026810 | `lazy-tf-state-ipp58n854uhpw13x` |

An Octopus project promoted dev→QA→prod must have `S3_BUCKET` / `TF_VAR_tf_state_bucket`
re-derived per environment scope. Copying the QA setup script and changing only the obvious
values leaves prod pointing at QA's bucket — which the prod worker cannot read.

**Why:** the failure is silent until the first state read. `terraform init` prints
"Successfully configured the backend "s3"!" without touching the bucket, so the log looks
healthy right up to `Error refreshing state: ... StatusCode: 403 ... Forbidden`.

**How to apply:** on any new env scope, check the state bucket against
`wip/prod-standup/add-prod-vars.py` (prod) or `add-qa-vars.py` (QA) before deploying. Treat
a bucket name as an identifier that resolves to an account — an env-hygiene check on account
IDs alone will not catch it ([[proxy-is-not-the-property]]). If a 403 persists *after* the
bucket is right, that is a different fault: S3 returns 403 not 404 for a missing key when
the caller lacks `s3:ListBucket`. See [[risingwave-prod-terraform-via-octopus]],
[[platform-admin-cannot-write-its-own-secrets]].

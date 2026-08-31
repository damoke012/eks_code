# INFRA-1674 — how RisingWave prod infrastructure actually gets built

Scope: `variant-inc/iaac-risingwave-onprem` @ `origin/main`, read 2026-08-31.
Account under discussion: op-usxpress-prod `937464026810`, OIDC issuer `d3rxit8f4yvshu`.

## The deployment mechanism

`deploy/terraform/` is environment-generic. Every input is a variable
(`cluster_name`, `oidc_issuer`, `region`, `namespace`, `service_account`,
`s3_bucket_prefix`, `aws_profile`) and the S3 backend block is **deliberately empty**
so a missing `-backend-config` fails loudly rather than silently landing in another
environment's state.

There are **no committed tfvars and no `backend-*.hcl`** — by design.
`deploy/deploy.ps1` (run by Octopus) exports every `TF_VAR_*` Octopus variable as an
env var, and takes the backend from `S3_BUCKET` / `TF_STATE_KEY` / `AWS_DEFAULT_REGION`.

Adding prod is therefore an **Octopus environment + variable scope**, not a module change.

| Octopus variable | prod value |
|---|---|
| `TF_VAR_cluster_name` | `op-usxpress-prod` |
| `TF_VAR_oidc_issuer` | `d3rxit8f4yvshu` |
| `TF_VAR_s3_bucket_prefix` | `risingwave-state-op-usxpress-prod` |
| `S3_BUCKET` / `TF_STATE_KEY` | prod state bucket, prod-specific key |
| `TfApply` | `true` |

Naming lines up with what `scripts/rw-prod-prereqs.sh` already checks for:
- `sm_prefix = "${var.cluster_name}/risingwave"` → `op-usxpress-prod/risingwave/*`
- IRSA role `name = "${var.cluster_name}-risingwave"` → `op-usxpress-prod-risingwave`
- bucket `= var.s3_bucket_prefix` (literal, no suffixing)

## The blocker — unconditional `import` blocks

`deploy/terraform/secrets.tf:45-72` carries five bare `import` blocks:

```hcl
import {
  to = aws_secretsmanager_secret.postgres
  id = "${local.sm_prefix}/postgres"
}
```
…and the same for `root`, `svc-reporting`, `secret_store_private_key`,
`console_license_key`. Added by Idris 2026-08-12 ("fix: import existing SM secrets and
protect secret values from overwrite") to adopt secrets a prior apply had created under
a different state key.

The in-file comment says *"import blocks are idempotent: if the resource is already in
state, TF skips"*. That is true for **already-in-state**. It is **not** true for a
remote object that does not exist: Terraform fails the plan with
`Cannot import non-existent remote object`.

op-usxpress-prod has **none** of the five (verified 2026-08-31, 8-of-8 MISSING).
So prod's first `terraform plan` errors on all five before creating anything.

The same comment already says *"Remove these blocks after the first successful apply
per environment."* That never happened, so the blocks are now a landmine for every
new environment.

### The fix — DONE, PR #31

`variant-inc/iaac-risingwave-onprem#31`, branch `fix/INFRA-1674-drop-import-blocks`,
opened 2026-08-31. 29 lines deleted from `secrets.tf`, one file, nothing else in the diff.
`terraform validate` passes; `terraform fmt -check` fails on a **pre-existing**
misalignment in `variables.tf` (`aws_profile`) that was deliberately left alone.

Not yet confirmed: that the removal is a plan no-op for dev and QA. The reasoning is
sound — an import block already consumed leaves nothing behind to remove — but it is
reasoning, not evidence. A QA plan showing "No changes" is the proof, and an Octopus
run with `TfApply=false` is the safe way to get it.

### The fix

Delete the five `import` blocks. Safe for dev and QA — their secrets are already in
their own state, so removing the block is a state no-op. Unblocks prod, which needs
creation, not adoption. If an environment ever needs adoption again, that is what the
`terraform import` CLI is for — it does not need to live in the committed config.

The alternative (guard with `for_each` over a `var.import_existing_secrets`, default
false) needs `required_version >= 1.7`; the file currently pins `>= 1.6`. Not worth it
for blocks whose own comment says they should already be gone.

## Terraform builds five of the six secrets

`secrets.tf` creates `postgres`, `root`, `svc-reporting`, `secret_store_private_key`,
`console_license_key`. **`dex_entra_client_secret` is not in Terraform** — it is
hand-created and depends on the prod Entra app registration. That puts the Entra
request on the critical path for the manifests, not beside it.

Three get generated values (`random_password`, `special = false` — punctuation breaks
quoting in connection strings under load); `secret_store_private_key` uses `random_id`.
Those four are self-sufficient.

`console_license_key` also gets a `secret_version`, so Terraform will create it
**holding whatever the config puts there** — existence must not be read as validity.
Same shape as the QA etcd-backup ExternalSecret: green sync, useless value.

## Traps

- **A green Octopus deploy is not an apply.** `deploy.ps1:76` gates apply on `TfApply`;
  when it is not `"true"` the script prints `[STEP] TfApply != true — plan only, no apply`
  and the deploy still reports **Success**. Same pattern as `iaac-talos`.
  **Proof of apply = `terraform_outputs.yml` attached as an Octopus artifact**
  (`deploy.ps1:80-86` writes it only on the apply branch). Green with no artifact
  means nothing was created.
- `deploy/terraform/s3.tf` is **an empty file, 0 lines**. The bucket, versioning, SSE
  and public-access-block all live in `main.tf:31-56`. Grepping s3.tf for the bucket
  returns nothing and means nothing.
- The `console_license_key` value is a placeholder until the lapsed licence is renewed
  (Steve → Zach). Creating the secret does not make the console work.

## Proven (2026-08-31)

- `deploy/terraform/` is environment-generic; prod needs no module change.
- Parameterisation is 100% Octopus variables; nothing about environments is committed.
- Resource names derived from `cluster_name` match the prereq script's expectations exactly.
- Five unconditional `import` blocks will fail prod's first plan.
- Terraform covers 5 of the 6 Secrets Manager paths; `dex_entra_client_secret` is manual.
- `apply` is conditional and a skipped apply still reports Success.

## Tested and killed

- **"Prod is a variables change, nothing to commit"** — wrong, corrected same session.
  The import blocks are a required repo change before any prod plan can run.
- **"s3.tf holds the bucket"** — it is empty. Two greps returned nothing and the
  conclusion drawn from them was that the files were on another branch. They were not:
  the greps were aimed at the wrong files (`locals` is in `secrets.tf`, the bucket is
  in `main.tf`). An empty grep is not evidence of absence — again.
- **"There must be per-environment tfvars somewhere"** — there are none, deliberately.

---

# Confirmation run — 2026-08-31, `scripts/rw-prod-confirm.sh`

Eight claims tested. Six held. Two changed the plan.

## Confirmed

- **op-usxpress-prod is `937464026810`** — reached via profiles `ops-controller` and `usx-prod`.
- **Prod's OIDC issuer `d3rxit8f4yvshu` is registered**:
  `arn:aws:iam::937464026810:oidc-provider/d3rxit8f4yvshu.cloudfront.net`.
  The IRSA trust policy will resolve.
- **QA's IRSA role is `op-usxpress-qa-risingwave`** — so `${var.cluster_name}-risingwave`
  is the real convention and prod's will be `op-usxpress-prod-risingwave`.
- **All five QA secrets exist** at `op-usxpress-qa/risingwave/*`.
- **`dex_entra_client_secret` is absent from all of `deploy/terraform/`** — hand-created.
- **`console_license_key` is created holding a literal placeholder**:
  `jsonencode({ RW_LICENSE_KEY = "PLACEHOLDER_INJECT_REAL_LICENSE" })`, with
  `lifecycle { ignore_changes = [secret_string] }`. Terraform creates it once and never
  touches it again. Existence proves nothing; the real key goes in by hand afterwards.
- **Prod DNS does not resolve**; QA's three names all answer with
  `10.10.82.23`, `10.10.82.139`, `10.10.82.106`.

## Changed the plan

### 1. `786352483360` is the **playground** account

Reached via profiles `infra-playground` and `playground`. It is not a typo for a prod
account — it is a real account we own, for throwaway work. INFRA-1675 as written would
have pointed the prod OIDC role ARN at the playground.

That value came from my write-up. Worth sweeping other notes for it.

### 2. QA already has a `dex_entra_client_secret` — the Entra pole may be much shorter

`op-usxpress-qa/risingwave/dex_entra_client_secret` **exists**. Someone has already done
the Entra work for QA. An app registration can carry more than one redirect URI, so prod
may not need a new registration at all — only prod's callback added to the existing one,
and the same client ID and secret reused.

Untested. But the difference between "new app registration from identity" and "add a
redirect URI to one that exists" is days.

### 3. QA has **two** RisingWave buckets, and Terraform builds one

    risingwave-state-op-usxpress-qa
    risingwave-data-op-usxpress-qa

`main.tf` creates a single bucket from `var.s3_bucket_prefix`. `rw-prod-prereqs.sh` only
ever checked for `risingwave-state-op-usxpress-prod`, so it would have reported a
complete prod build while `risingwave-data-op-usxpress-prod` was still missing.

Which of the two Terraform owns, and where the other comes from, is not yet known.
This is the "one sample is not a population" trap: the prereq script was written from
one bucket name and would have passed on half the storage.

## Also noted

Account `937464026810` holds **both** the on-prem prod OIDC provider and the cloud prod
EKS cluster's (`BF7BD0896246A3AA0A5DF5C9D8200E8A`). On-prem prod and cloud prod share
an account.

## Trap found in the check itself

`rw-prod-confirm.sh`'s import-block count reported `MISMATCH 0` for a correct answer:
`grep -c` prints `0` *and* exits 1 on no match, so `|| echo 0` appended a second zero and
`"0\n0" != "0"`. Fixed. The check was right and its verdict was wrong — the same shape as
the probe that reported UNSUPPORTED because psql was missing.

## What

Removes the five `import` blocks from `deploy/terraform/secrets.tf` — `postgres`, `root`, `svc-reporting`, `secret_store_private_key`, `console_license_key` — along with their comment header. 29 lines deleted, nothing else changed.

## Why

An `import` block is idempotent only for an object **already in state**. For a remote object that does not exist, Terraform fails the plan:

```
Cannot import non-existent remote object
```

The blocks were added in "fix: import existing SM secrets and protect secret values from overwrite" (2026-08-12) to adopt secrets that a prior apply had created under a different state key. That job is done for dev and QA.

We are now standing RisingWave up on **op-usxpress-prod** (account `937464026810`), where none of the five secrets exist — verified 2026-08-31, 8 of 8 prerequisites missing. Prod's first `terraform plan` therefore errors on all five before creating anything.

The file's own comment already anticipated this:

> Remove these blocks after the first successful apply per environment.

That never happened, so the blocks have become a landmine for every new environment.

## Blast radius

**None for dev or QA.** Their secrets are already in their respective state files, so removing an `import` block that has already been consumed is a state no-op — the next plan for either environment shows no changes.

If an environment ever needs adoption again, that is what the `terraform import` CLI is for. It does not need to live in the committed config, where it applies unconditionally to every environment including ones that do not exist yet.

## Verification

```
terraform fmt -check -diff
terraform init -backend=false && terraform validate
```

Plan for dev and QA should be a no-op. Worth confirming on one of them before merge.

## Not in this PR

- The prod Octopus environment and variable scope (`cluster_name`, `oidc_issuer`, `s3_bucket_prefix`, backend key) — separate change, no repo edit.
- `manifests/op-usxpress-prod/` — separate, and blocked on the secrets and IRSA role existing first.
- `deploy/terraform/s3.tf` is an empty 0-line file; the bucket lives in `main.tf`. Left alone deliberately — deleting it is unrelated tidying.

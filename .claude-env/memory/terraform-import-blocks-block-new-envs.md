---
name: terraform-import-blocks-block-new-envs
description: iaac-risingwave-onprem's five bare `import` blocks in secrets.tf fail the first plan in any environment where the secrets do not yet exist — prod is blocked on deleting them
metadata:
  type: project
---

`variant-inc/iaac-risingwave-onprem` @ `deploy/terraform/secrets.tf:45-72` carries five
unconditional `import` blocks (`postgres`, `root`, `svc-reporting`,
`secret_store_private_key`, `console_license_key`), added by Idris 2026-08-12 to adopt
secrets an earlier apply had made under a different state key.

An `import` block is idempotent only for an object **already in state**. For a remote
object that does not exist, Terraform fails the plan: `Cannot import non-existent remote
object`. op-usxpress-prod (937464026810) has none of the five — verified 2026-08-31,
8 of 8 prerequisites missing — so prod's first plan errors before creating anything.

**Fix:** delete the five blocks. It is a state no-op for dev and QA (already adopted) and
unblocks prod, which needs creation not adoption. The file's own comment already says
"Remove these blocks after the first successful apply per environment" — it never happened.

**Why:** this is the one repo change prod needs. Everything else about
`deploy/terraform/` is environment-generic — see [[risingwave-prod-terraform-via-octopus]].

**How to apply:** before scheduling any prod Octopus deploy for
`iaac-risingwave-onprem`, confirm the import blocks are gone from the branch being
deployed. Related: [[rw-prod-blocked-on-manifests-path]], [[eso-secretsynced-not-content-check]].

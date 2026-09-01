# INFRA-1674 — RisingWave on op-usxpress-prod — state at 2026-09-01

**One action remains: create a release and deploy to `production`.**
Everything else is merged, live, or staged behind it.

Octopus prod variables written and verified 2026-09-01 — 10 production-scoped entries on
`Projects-10241`. `TfApply` deliberately NOT among them, so the first prod deploy is
plan-only on its own.

## Done and live

| | |
|---|---|
| `manifests/op-usxpress-prod/` (24 files) | `iaac-risingwave-onprem` #32, merged |
| Unconditional `import` blocks removed from `secrets.tf` | #31, merged |
| Prod routes corrected (were dev copies), `tcp-passthrough` Gateway, Velero metastore Schedule | `iaac-talos-flux-platform` #143, merged into `op-prod` and reconciled at `7f0d3b7` |
| `op-usxpress-prod/risingwave/dex_entra_client_secret` | created by hand 2026-09-01, 40 chars, verified against QA's value |

## Staged, waiting on the deploy

`scripts/wire-prod-risingwave.py` + `wip/rw-etl-promotion/prod-infra-risingwave-block.yaml`
append the GitRepository and three Kustomizations (`risingwave-operator`,
`risingwave-onprem`, `risingwave-routes`) to prod's `infra.yaml`, and rewrite the
"deliberately absent" header note rather than deleting it.

It **refuses** until all six secrets, the IRSA role and the bucket exist. Verified
refusing 2026-09-01 with 5 secrets + role + bucket missing.

## Preflight — all green 2026-09-01

| Gate | Result |
|---|---|
| Release built from current main | `0.5.4`, assembled 18:26, **package `0.5.4`** |
| Production variables | 10, verified on read-back |
| Lifecycle reaches production | `iaac-release` (Lifecycles-42) has a production phase |
| `TfApply` armed for prod? | **No** — first prod deploy is plan-only |
| Worker pool | `WORKER_POOL [production] = WorkerPools-1582` = `usxpress-production`, 2/2 healthy |

**Do not promote release `0.5.3`.** It selects package `0.5.1` from 2026-08-12, which
predates both the prod manifests and the import-block removal. Its version and package
version differ — that inequality is the tell.

**Why `0.5.4` had to be forced.** The releases are cut by `octo.yaml` on push, and the
version comes from **conventional commit prefixes**. Both INFRA-1674 merges used
`INFRA-1674: ...`, so no bump, no package, and the run still reported success plus
"Create/Update Release complete" while updating `0.5.3` in place. `fix: remove the empty
s3.tf` produced `0.5.4`. See [[conventional-commits-drive-releases]].

The `dpl` deployment failures (branch pushes and 0.5.4) are `WorkerPools-286` having
0/0 workers. Not ours, not related.

## The deploy

Octopus project `iaac-risingwave-onprem`, new prod environment:

    TF_VAR_cluster_name      op-usxpress-prod
    TF_VAR_oidc_issuer       d3rxit8f4yvshu
    TF_VAR_s3_bucket_prefix  risingwave-state-op-usxpress-prod
    S3_BUCKET / TF_STATE_KEY prod state, prod-specific key
    TfApply                  true

**Green is not applied.** `deploy.ps1` gates apply on `TfApply` and a skipped apply still
reports Success. The proof is `terraform_outputs.yml` attached as an Octopus artifact —
it is written only on the apply branch.

## Then

1. `wire-prod-risingwave.py ... --write`, PR to `iaac-talos-flux-cluster` master
2. Merge; Flux brings up the operator, the RisingWave CR and the routes
3. DNS appears on its own — external-dns writes it from the VirtualService annotations
4. Real licence into `console_license_key` (Steve/Zach) — console only

## Open, not blocking

- **Velero backup on prod** — Schedule is Enabled; confirm a real backup ~6h after
  2026-09-01 morning. The object existing proves nothing.
- **Next QA Terraform plan** — the check #31 skipped. "No changes" means the import-block
  removal was safe; wanting to create the five secrets means revert before any apply.
- **`risingwave-pipeline` #19** — one change requested (`RW_NS` mapped per environment,
  since `risingwave-2` is dev-only). Approve when it lands.
- **#18** — 112 files under a title about one ARN; asked Idris to split or close.
- **Prod Grafana VirtualService** still publishes `grafana.op-dev.usxpress.io`.
- **Entra redirect URI** for prod's callback — console, not yet done.
- **Revoke**: the Atlassian API token and both Confluent credential pairs. Still live.
- **Job 130 wedged on op-dev** — needs Tim's call on `RECOVER`.

## 2026-09-01 — release 0.5.6 deployed to production, FAILED at terraform init (403)

Release `0.5.6` (channel `release`, pins package `0.5.5`) reached the production worker and
died reading state: `S3_BUCKET` in production scope was **QA's** bucket
`lazy-tf-state-425rbol87rmn6c7m`. Prod's is `lazy-tf-state-ipp58n854uhpw13x`. Plan-only run,
nothing created. Full write-up + why two of my own checks passed over it:
`PROD-DEPLOY-403-2026-09-01.md`. Fix is in `scripts/setup-octopus-rw-prod.py` (`--fix`).
Release 0.5.6 is still good — re-deploy it after the variable is corrected.

## 2026-09-01 19:35 — PROD TERRAFORM APPLIED (INFRA-1674)

Release `0.5.6` -> `production`, `TfApply=true` armed for the one run then disarmed.
`Apply complete! Resources: 20 added, 0 changed, 0 destroyed.` Artifact
`terraform_outputs.yml` uploaded — that, not the green task, is the proof it applied.

Created in 937464026810 / us-east-2:
- `arn:aws:iam::937464026810:role/op-usxpress-prod-risingwave` (IRSA, trust on
  `d3rxit8f4yvshu.cloudfront.net`) + inline policy `risingwave-s3-access`
- `s3://risingwave-state-op-usxpress-prod` — versioning, SSE, public-access-block on
- five Secrets Manager secrets + versions under `op-usxpress-prod/risingwave/`:
  `root`, `postgres`, `svc-reporting`, `secret_store_private_key`, `console_license_key`

Two failed runs preceded it, both `403 HeadObject`: `S3_BUCKET` in production scope held
QA's bucket, and after correcting it the release still deployed its FROZEN snapshot. See
`PROD-DEPLOY-403-2026-09-01.md` and [[octopus-release-freezes-variables]].

**Next:** wire Flux (`scripts/wire-prod-risingwave.py --write` -> PR to
`iaac-talos-flux-cluster` master). **Still placeholder content:** `console_license_key`
holds a generated value, not the real licence (Steve/Zach). A green ExternalSecret will
not tell you that.

## 2026-09-01 ~19:55 — RisingWave RUNNING on op-usxpress-prod; one blocker left

PR variant-inc/iaac-talos-flux-cluster#38 merged. Flux applied
`master@sha1:33efcd97`. `RisingWave/risingwave/risingwave` reports RUNNING=True,
v2.8.2, PostgreSQL metastore + S3 state store. meta/compute/frontend/compactor,
both ghostunnels and pg-postgresql all 1/1. All seven ExternalSecrets SecretSynced.
`risingwave-routes` applied `op-prod@sha1:7f0d3b7`.

**Blocker: the console licence.** `console_license_key` holds the value Terraform
generated. The console rejects it — `license verification failed: license must be a
compact JWT` — so `risingwave-console` crashloops, the `anclax` schema is never created,
and `rw-bootstrap-service-accounts` crashloops on its final step
(`relation "anclax.users" does not exist`) despite completing every group, user and
grant successfully. ONE secret value, two red components.

Owner: Steve/Zach. Until it lands, prod RisingWave is usable as a database and unusable
through the console UI.

**CHECKED 2026-09-01 — there is nothing to copy.** QA's `console_license_key` holds the
IDENTICAL 52-char placeholder JSON as prod (`{"R…`, one part; a real licence is a compact
JWT — three parts, `eyJ`). So no environment has ever had a real console licence. The ask
to Steve/Zach is ONE licence for the whole on-prem estate, not a prod key. Open: whether
QA's console pod is actually running (op-qa unreachable at the time — VPN/SSO).

**Also still open:** prod's Entra redirect URI
`https://risingwave-dashboard.op-prod.usxpress.io/dex/callback` on app registration
`e112d6ce-cc60-4884-9898-8fcc5b78b0b1`, and a first COMPLETED Velero backup (~6h).

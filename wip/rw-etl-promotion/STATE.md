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

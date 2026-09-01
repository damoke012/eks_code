# INFRA-1674 — RisingWave on op-usxpress-prod — state at 2026-09-01

**One action remains: the Octopus prod deploy of `iaac-risingwave-onprem`.**
Everything else is merged, live, or staged behind it.

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

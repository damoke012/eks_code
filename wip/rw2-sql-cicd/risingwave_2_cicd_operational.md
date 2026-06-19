---
name: risingwave-2-cicd-operational
description: "risingwave-2 CICD env on op-usxpress-dev is OPERATIONAL as of 2026-05-26. Full GitOps deployment in isolated namespace, separate from Tim's prod risingwave. Driven by variant-inc/iaac-risingwave-2 (data plane) + cluster repo Option G consolidation. AWS resources being brought into Terraform via iaac-talos PR #29."
metadata: 
  node_type: memory
  type: project
  originSessionId: 4b4e33f8-6d64-42b6-8c41-64ab18b78bc3
---

# risingwave-2 CICD environment — operational state (as of 2026-05-26)

## Headline
RisingWave CR shows `RUNNING=True` in `risingwave-2` namespace. Full GitOps pipeline working end-to-end. Tim's prod `risingwave` ns untouched throughout (7 pods Running, `risingwave-frontend-lb` NodePort 32567).

**Why:** Independence from Tim/Idris's `iaac-risingwave-onprem` repo (we only have pull there). On-prem platform team controls the CICD track via `variant-inc/iaac-risingwave-2`. Promotion to prod is forward-only PR.

**How to apply:** When a RW change is needed (image bump, chart upgrade, CR tweak), edit `iaac-risingwave-2/manifests/op-usxpress-dev/*.yaml`, commit + merge to main. Flux reconciles automatically (5-min source interval, manual via `flux reconcile`). When stable, PR upstream to `iaac-risingwave-onprem`.

## Architecture (Option G consolidation, post 2026-05-26)

- `variant-inc/iaac-risingwave-2` (main) — data plane manifests (postgres HR, prometheus HR, RW operator HR, RisingWave CR, ExternalSecrets, namespace, SA).
- `variant-inc/iaac-talos-flux-cluster` (master) `clusters/bm-dev/flux-system/infra.yaml` — inline `GitRepository iaac-risingwave-2` + `Kustomization risingwave` sourcing it directly. **No nesting** (was the source of the previous parent/child name conflict; merged as iaac-talos-flux-cluster PR #3).
- `variant-inc/iaac-talos-flux-platform` (op-dev) — `infrastructure/risingwave/` deleted as dead code via PR #7.
- `variant-inc/iaac-talos` (feature/op-usxpress-dev) — IAM + S3 codification merged via PR #29 (squashed to `e34da91`). Release 1.140 applied 2026-05-26.
- `variant-inc/iaac-risingwave-cicd` (main) — architecture + ops runbook + new-env templates. Initial commit 7402d4a.

See [reference: RisingWave CICD repos](reference_risingwave_2_repos.md) for the link table.

## Per-env AWS resources (2026-05-26)

- S3 bucket: `risingwave-data-op-usxpress-dev` (us-east-2). Public access fully blocked. TF-managed via `module.irsa[0].aws_s3_bucket.risingwave_2_data`.
- IAM role: `op-usxpress-dev-risingwave-2`. Trust pinned to `system:serviceaccount:risingwave-2:risingwave` on the cloudfront OIDC (`d3a7wcnazdrd6p.cloudfront.net`). TF-managed.
- IAM policy: inline `s3-hummock` on the role (TF `aws_iam_role_policy.risingwave_2_s3`). Grants GetObject/PutObject/DeleteObject/AbortMultipartUpload/ListMultipartUploadParts on bucket objects + ListBucket/GetBucketLocation on bucket.
- Orphan managed policy `op-usxpress-dev-risingwave-2-s3` (pre-codify): **detached + deleted 2026-05-26** after inline policy verified active.

## AWS Secrets Manager — SPLIT 2026-05-26
- `op-usxpress-dev/risingwave-2/postgres` (username, password) — used by `pg-credentials` ExternalSecret.
- `op-usxpress-dev/risingwave-2/root` (password) — used by `rw-root-credentials` ExternalSecret + `rw-bootstrap-root-password` Job.
- `op-usxpress-dev/risingwave-2/console_license_key` (RW_LICENSE_KEY) — created but **NOT YET WIRED**: `rw-license-key.yaml` exists in repo but is omitted from `kustomization.yaml` resources list. Awaiting license-key value from Idris before adding it.

Migration was same-value (no rotation): copied existing prod values into the new paths so existing K8s secret values stayed identical and pods didn't restart. Tim's prod still reads from `op-usxpress-dev/risingwave/*` (untouched).

**Future**: rotate passwords away from defaults. Currently both prod AND risingwave-2 share `risingwave/risingwave` bitnami defaults for postgres (literally the chart defaults). Rotate independently per env now that the paths are separate.

## Manual one-time fixes still to codify
- `local-path-storage` namespace label `pod-security.kubernetes.io/enforce=privileged` (applied manually 2026-05-26 to unblock PVC provisioner helper pods). Should be codified in iaac-talos via `kubernetes_labels` resource since K8s provider is already configured. See [[feedback-local-path-helper-runs-in-local-path-storage-ns]].

## Open work
- Codify `local-path-storage` ns PodSecurity label as Terraform (`kubernetes_labels` resource)
- Wire `rw-license-key.yaml` into `kustomization.yaml` resources list — **blocked** on license-key value from Idris
- Stand up `risingwave-pipeline` repo (Idris creating) for Kafka/Mongo connector configs + SQL pipeline definitions
- Rotate prod + risingwave-2 SM passwords away from bitnami defaults (`risingwave/risingwave`) — now independent post-split
- Phase 2 worker memory expansion 4Gi → 8Gi (this weekend per user note 2026-05-26)

## Completed in this arc (2026-05-26)
- ✅ TF apply landed via Octopus release `0.1.0-feat-risingwave-2-irsa-codify.1.140` (TfApply=true, flipped back to false after)
- ✅ Orphan managed policy detached + deleted; inline `s3-hummock` confirmed sole policy on role
- ✅ PR #29 squash-merged to `feature/op-usxpress-dev` (commit `e34da91`)
- ✅ RW-2 pods stayed healthy through IAM transition (no restarts)
- ✅ Tim's prod `risingwave` ns untouched throughout (RUNNING=True for 26d unchanged)
- ✅ SM paths split per env — iaac-risingwave-2 commit `85c6790`. pg-credentials + rw-root-credentials ExternalSecrets now point at `/risingwave-2/*` paths. License-key SM secret created but ExternalSecret intentionally not wired yet.
- ✅ iaac-risingwave-cicd docs repo updated locally (commit `41cf946`) with codification + SM split + Idris pipeline plan. **Pending push to enterprise GitHub** (repo not yet created — user will create + push).
- ✅ Discovered: `rw-license-key.yaml` was never deployed in risingwave-2 because it's omitted from `kustomization.yaml` resources list. Explains the "secret keeps getting wiped" mystery in [[rw-pg-credentials-and-license-key-secrets-lifecycle-unknown]] for the risingwave-2 case (prod cause was separate flux_bootstrap_git cascade, since fixed via Option B).

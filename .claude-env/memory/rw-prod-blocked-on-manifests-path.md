---
name: rw-prod-blocked-on-manifests-path
description: RisingWave is absent from op-usxpress-prod DELIBERATELY — iaac-risingwave-onprem has no manifests/op-usxpress-prod dir, and wiring it early caused a 17-day "path not found" failure
metadata:
  type: project
---

**INFRA-1674** (created 2026-08-31, UI Sprint 4, In Progress, dare).

The reason prod has no RisingWave is **written in the code**, at
`iaac-talos-flux-cluster: clusters/op-usxpress-prod/flux-system/infra.yaml:22-23`:

    # RisingWave: deliberately absent — ./manifests/op-usxpress-prod does not exist
    # in iaac-risingwave-onprem yet; wiring it = the 17-day "path not found" failure.

**So the work is in `iaac-risingwave-onprem`, not the platform or cluster repo.** Create
`manifests/op-usxpress-prod/` there FIRST, then add the GitRepository + Kustomization block to
prod's `infra.yaml`, mirroring `clusters/op-usxpress-qa/flux-system/infra.yaml:533-679`
(INFRA-1624). Wiring the Kustomization before the path exists is the failure the comment
warns about — Flux reports "path not found" and it went unnoticed for 17 days.

QA's block is the template: `GitRepository iaac-risingwave-onprem` -> Kustomization
`risingwave-operator` (CRDs + controller first) -> Kustomization `risingwave-onprem`
(healthChecks on the `RisingWave` CR) -> Kustomization `risingwave-routes` pointing at
`./infrastructure/risingwave-routes` **on the platform repo**. Prod needs its own
`risingwave-state-op-usxpress-prod` S3 bucket.

⚠️ **op-prod's six route files in `iaac-talos-flux-platform` are DEV COPIES** — verified
2026-08-31. They publish `risingwave-dashboard.op-dev.usxpress.io`,
`rw-sql.op-dev.usxpress.io`, `rw-postgres.op-dev.usxpress.io` and target **dev's** seven
workers (10.10.82.21/.22/.26/.27/.28/.178/.180). The INFRA-1645 correction comments — which
describe this exact bug being fixed on op-qa on 2026-08-20 — have been REMOVED from the prod
copies. Tenth instance of [[manifests-copied-across-branches]]. Fix before wiring, or prod
serves dev's hostnames and nothing looks wrong.

**Also missing on prod:** `infrastructure/velero/risingwave-metastore-schedule.yaml` is
op-qa-only (line 19 says `op-usxpress-qa`). Prod would have **no backup schedule for the
RisingWave meta store**.

**Open question, not yet answered:** `infrastructure/arc-runner-rw-pipeline/` exists on the
**op-qa** branch. Our notes say only dev has an ARC runner — see [[onprem-app-cicd]]. Either
QA has one we did not know about, or it is on the branch and not reconciled. This matters
because "QA has no in-cluster runner" is load-bearing in the CI/CD argument.

`feat/op-prod-full-platform` on the cluster repo has **zero unique commits** — already merged,
not a missing piece.


## 2026-08-31 — a second prod gap, found while confirming DNS

op-usxpress-prod has the `shared-http` Istio Gateway (80, 443) but **no `tcp-passthrough`**
(4567, 5432), which op-usxpress-qa has. The prod `istio-ingressgateway` Service already
exposes both ports, so only the Gateway resource is missing — `rw-sql` and `rw-postgres`
would resolve, reach a platform node, and route nowhere. Lives in `iaac-talos-flux-platform`,
`op-prod` branch, under `infrastructure/`. See [[onprem-ingress-dns-convention]].

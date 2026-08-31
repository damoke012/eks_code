---
name: onprem-gitops-repo-topology
description: FOUR repos deliver the on-prem clusters and each owns a different layer — RisingWave itself is in NEITHER the platform nor the cluster repo; cluster repo is single-branch, platform repo is per-cluster branches
metadata:
  type: reference
---

Verified 2026-08-31 by reading all three repos. Getting this wrong cost most of a session
looking for the RisingWave operator in the wrong repository.

| Repo | Branch model | Owns |
|---|---|---|
| **`iaac-talos-flux-cluster`** | **single `master`**, dirs `clusters/<cluster>/flux-system/infra.yaml` | the Flux `GitRepository` + `Kustomization` objects that point at everything else. The wiring, not the content. |
| **`iaac-talos-flux-platform`** | **per-cluster branches** `op-dev` / `op-qa` / `op-prod` | `infrastructure/*` — routes, app-namespaces, kyverno, prometheus, rbac, reloader, velero, argocd |
| **`iaac-risingwave-onprem`** | `manifests/<cluster>/` per environment | **the RisingWave operator + the `RisingWave` CR.** The actual product. |
| **`iaac-risingwave-2`** | — | Tim's separate `risingwave-2` namespace. Wired on `bm-dev` ONLY. |

⚠️ **Two different branch models in two repos.** `op-qa`/`op-prod` are valid refs in
`iaac-talos-flux-platform` and DO NOT EXIST in `iaac-talos-flux-cluster` — that one is
`master` plus feature branches. A `git fetch origin op-qa` there fails with
"couldn't find remote ref".

⚠️ **RisingWave is in NEITHER the platform nor the cluster repo.** All three platform
branches (dev, qa, prod) contain only `risingwave-routes/`, `app-namespaces/app-risingwave.yaml`
and passing mentions in kyverno/prometheus/rbac. **No operator, no HelmRelease, no instance** —
not even on op-dev, where RisingWave demonstrably runs. Searching the platform repo for the
operator returns a small, clean, wrong answer. See [[adjacent-step-green-signals]].

⚠️ **Cluster dir for on-prem DEV is `bm-dev`**, not `op-usxpress-dev`. QA and prod use
`op-usxpress-qa` / `op-usxpress-prod`.

**S3 state buckets** are per cluster: `risingwave-state-op-usxpress-dev`,
`risingwave-state-op-usxpress-qa`. Prod would need `risingwave-state-op-usxpress-prod`.

Related: [[onprem-app-cicd]], [[manifests-copied-across-branches]], [[prod-standup]].

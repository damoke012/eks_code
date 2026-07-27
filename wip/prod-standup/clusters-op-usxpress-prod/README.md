# clusters/op-usxpress-prod/ — install note

Drafted 2026-07-24 by replicating `clusters/op-usxpress-qa/flux-system/` (which Doke
pasted from the live repo). Four of the five files are here; `gotk-components.yaml` is
NOT — it's identical boilerplate across every cluster, so copy QA's verbatim.

## How to install (on WSL, in iaac-talos-flux-cluster on master)

```bash
cd ~/work/iaac-talos-flux-cluster/clusters
mkdir -p op-usxpress-prod/flux-system
cp op-usxpress-qa/flux-system/gotk-components.yaml op-usxpress-prod/flux-system/   # verbatim
cp ~/work/eks_code/wip/prod-standup/clusters-op-usxpress-prod/flux-system/*.yaml \
   op-usxpress-prod/flux-system/
```

Then PR to `master`. The directory won't do anything until the prod cluster exists and
Flux bootstraps against it (flux_target_path=clusters/op-usxpress-prod, set in the
Octopus vars) — a dir-per-env on master, so no branch needed here.

## What differs from op-qa (the only env-specific edits)

| File | Change |
|---|---|
| `infra-source.yaml` | platform branch `op-qa` → **`op-prod`** |
| `gotk-sync.yaml` | reconcile path → **`./clusters/op-usxpress-prod`** |
| `infra.yaml` | **phased** — AWS-free core active, everything IRSA-dependent + argocd in a commented phase-2 block; **RisingWave removed** (prod manifests path doesn't exist yet) |
| `kustomization.yaml` | identical |
| `gotk-components.yaml` | identical (copied) |

## Two milestones, deliberately

1. **Cluster exists** — phase-1 core reconciles with no external dependency. Do now.
2. **Platform functional** — uncomment phase-2 in `infra.yaml` AFTER cloud provisions
   the prod IRSA bootstrap (OIDC + `ONPREM_BOOTSTRAP_ROLE_ARN_PROD`) and enable_irsa=true.
   Without it ESO can't read SM and nothing AWS-touching works.

## Dependency to resolve before phase 2

- E2/E3 on op-prd branch so etcd-backup targets `10.10.82.52`, not a copied VIP
- Seed the 3 platform SM secrets (grafana admin, grafana azure-ad, argocd admin)
- The prod IRSA bootstrap from cloud — the one genuine remaining external ask

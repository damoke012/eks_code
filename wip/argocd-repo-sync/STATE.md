# Argo CD repo-sync (PR #73) — STATE

**PR:** variant-inc/iaac-talos-flux-platform #73 "Chore/flux argocd repo sync"
**Author:** ifagbemi-usxpress (Idris)  •  **Base:** op-dev  •  **Head:** chore/flux-argocd-repo-sync
**Size:** +67,612 / −1, 17 files, 5 commits  •  **Checks:** 6/6 pass  •  **Reviewer:** dare-x (Doke)

## Decision: DO NOT MERGE — recommend CLOSE (Round 1 VERIFIED on WSL, 2026-07-10)

Not a chore. Adds Argo CD (2nd GitOps controller) pointed at a repo+ns Flux ALREADY reconciles.

## Blockers (ALL VERIFIED on WSL 2026-07-10)
1. ✅ CONFIRMED — direct collision. Argo CD app repoURL=`git@github.com:variant-inc/iaac-risingwave-onprem.git`, destination ns=`risingwave`. Flux already reconciles this: `flux get kustomizations` shows `risingwave-onprem` (Ready=True, iaac-risingwave-onprem@main) + `risingwave` + `risingwave-routes`. Same source + same ns = split-brain in Tim's prod ns. (Note: iaac-risingwave-onprem is now Flux-managed — INFRA-1487 A2 landed since the 2026-05-28 STATE snapshot.)
2. ✅ CONFIRMED — `argocd_git_secret.yaml` commits a real `sshPrivateKey`. Key is compromised → ROTATE now (independent of PR) + deliver via ESO from SM.
3. ✅ CONFIRMED — destination ns=`risingwave` = Tim's. Tim coord mandatory.
4. +67,612 lines — not separately chased; moot given close recommendation.

## Advisory
5. Argo CD server NodePort 31311/32119 vs live Istio ingress plane.
6. ServerSideApply=true field-ownership (compounds #1).
7. Scope creep — Grafana/Prometheus/dashboards bundled; split for clean rollback.

## Recommended solution (2026-07-10)
RW is ALREADY Flux-GitOps (RW-2 operational since 5/26; `infrastructure/risingwave/` deleted as dead code in PR #7). No Argo CD decision exists. **Do the repo-sync in Flux** (GitRepository + Kustomization + SSH key via ESO), wired in iaac-talos-flux-cluster — mirrors the operational RW-2 pattern / INFRA-1487 Option B. Full proposal + drop-in manifests + message to Idris: `recommended-solution.md`.

## Next
- Send Idris the recommended-solution (Flux equivalent), ask him to close/convert #73.
- Salvage the Grafana No-Data fix (9953ad1) + dashboards as a separate small PR.
- If the Flux redo targets `risingwave` (Tim's ns) → Tim coord (INFRA-1487), prune:false first reconcile.
- Optional live confirm on WSL: which repo does repo_sync.yaml point at? (see pr-73-review-2026-07-10.md)

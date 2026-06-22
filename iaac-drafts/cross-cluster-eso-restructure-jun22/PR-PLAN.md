# PR plan — IaC restructure post-2026-06-22 Rook + ESO recovery

**Context:** During 2026-06-22 we recovered op-usxpress-dev from a 32-day stuck `external-secrets-config` cascade AND a 3-day Rook OSD outage. This document captures the IaC changes needed to (a) prevent the failure modes from recurring on op-usxpress-dev, and (b) bootstrap a future QA cluster cleanly without manual intervention.

## PRs to file (in order)

### PR-A — Split cross-cluster CSS into its own Kustomization (iaac-talos-flux-platform)

Target: `iaac-talos-flux-platform` branch `op-dev`

Changes:
1. **New directory** `infrastructure/cross-cluster-eso/` containing:
   - `kustomization.yaml`
   - `clustersecretstore.yaml` (cloud-eks CSS only — moved from external-secrets-config/)
   - `onprem-platform-rbac.yaml` (moved as-is from external-secrets-config/)

2. **Trim** `infrastructure/external-secrets-config/`:
   - `clustersecretstore.yaml` → only the `default` (AWS SM) CSS
   - REMOVE `onprem-platform-rbac.yaml` from this directory (moved to cross-cluster-eso/)
   - Update `kustomization.yaml` resources list to remove the moved file

3. **New directory** `infrastructure/rook-recovery-jobs/`:
   - `README.md` — explains these are manual-apply templates
   - `osd-wipe.yaml` — privileged wipe pod
   - `bluestore-inspect.yaml` — read-only bluestore label dump
   - `toolbox.yaml` — always-on rook-ceph-tools deployment

   Note: this directory is NOT added to any Flux Kustomization. Manual apply only.

Source manifests for these directories are drafted in this `iaac-drafts/cross-cluster-eso-restructure-jun22/` folder.

### PR-B — Add cross-cluster-eso Kustomization to flux-cluster (iaac-talos-flux-cluster)

Target: `iaac-talos-flux-cluster` branch `master` (cluster: bm-dev)

Changes:
- In `clusters/bm-dev/flux-system/infra.yaml`, ADD a new Kustomization block:

  ```yaml
  ---
  apiVersion: kustomize.toolkit.fluxcd.io/v1
  kind: Kustomization
  metadata:
    name: cross-cluster-eso
    namespace: flux-system
  spec:
    interval: 10m
    sourceRef:
      kind: GitRepository
      name: infra
    path: ./infrastructure/cross-cluster-eso
    prune: true
    wait: false       # KEY — does not block on CSS Ready since CSS depends on Octopus runbook
    timeout: 5m
    dependsOn:
    - name: external-secrets
  ```

- `external-secrets-config` Kustomization unchanged (still wait: true; only contains the `default` CSS now, which is trivially Ready).

### PR-C — Toolbox always-on (iaac-talos-flux-platform)

Could land same PR as PR-A or separate.

Changes:
- In `infrastructure/rook-ceph-operator/` (or a new `infrastructure/rook-ceph-toolbox/` if cleaner), add the toolbox Deployment from `iaac-drafts/.../rook-recovery-jobs/toolbox.yaml`.

Note: only deploy toolbox AFTER rook-ceph-operator + rook-ceph-cluster are Ready. So if it's a separate Kustomization, add `dependsOn: rook-ceph-cluster`.

### PR-D — Catalog entries to iaac-talos enterprise repo

Target: `iaac-talos` branch `feature/op-usxpress-dev`

Changes:
- Add files under `deploy/docs/troubleshooting/`:
  - `02-storage/rook-osd-keyring-missing.md` (rewritten with PROVEN sequence)
  - `02-storage/rook-osd-pg-peering-crash.md` (new)
  - `04-secrets-credentials/external-secrets-config-cascade.md` (new)
  - `README.md` (updated symptom index)
  - `QA-CLUSTER-BOOTSTRAP-CHECKLIST.md` (new — phase-by-phase bootstrap order)

Source markdown is in `wip/onprem-troubleshooting/` in the codespace.

## Ordering of merges + Octopus actions

```
1. PR-A (iaac-talos-flux-platform) → merge to op-dev
2. PR-B (iaac-talos-flux-cluster) → merge to master
3. Wait for Flux to reconcile both repos on op-usxpress-dev
4. Verify:
   - external-secrets-config Ready=True (just the default CSS now)
   - cross-cluster-eso Ready=True (wait: false; deploys the manifests)
   - cloud-eks CSS still Ready=False (expected until runbook seeds)
5. Run "Seed Cross-Cluster ESO Token" Octopus runbook (once OnPremise space exists)
6. cloud-eks CSS goes Ready=True
7. (Future) Re-add the geoenrichment ExternalSecret manifests (the comment-blocked versions)
8. PR-D (iaac-talos catalog docs) → merge to feature/op-usxpress-dev
9. PR-C (toolbox) → merge to op-dev when ready
```

## Acceptance criteria

- `flux get kustomizations -A | awk '$4!="True"'` returns header-only on op-usxpress-dev
- Re-creating a fresh cluster from this IaC should NOT encounter the chicken-and-egg cascade
- `rook-ceph-tools` deployment present in `rook-ceph` ns by default (no ad-hoc apply needed)
- Catalog entries live in enterprise repo + surface via `/onprem-troubleshooting` skill

## Out of scope (file as separate INFRA tickets)

- OnPremise Octopus space setup + onprem-platform-bootstrap project deployment
- Mon PVC size increase (currently 21-27% available)
- pod-identity-webhook caBundle refresh post CP-rebuild
- PromRules: RookCephOSDDown, RookCephClusterDegraded, ClusterSecretStoreNotReady (≥1h)

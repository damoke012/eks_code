# Rook restore-readiness PR plan — 3 PRs, ship in order

**Goal:** Cluster auto-recovers from disaster (talos destroy + recreate, or any cold-start) **without manual intervention beyond the documented INFRA-1535 Octopus runbook**. Specifically closes the IaC gaps surfaced in the 2026-06-22 audit:

- Toolbox not Flux-managed (cold-start would lack ceph CLI)
- No PromRules / ServiceMonitor for Ceph health (HEALTH_WARN today undetected)
- Mon PVCs sized 10Gi → currently 21-27% available (will fill)
- Geoenrichment ES blocked in comment-block (manual restore required after runbook)
- external-secrets-config Kustomization on `wait: false` (incident workaround, no longer needed)

## PR-C — Rook IaC comprehensive (iaac-talos-flux-platform op-dev)

### Files added
- `infrastructure/rook-ceph-cluster/toolbox.yaml` — always-on ceph CLI Deployment (moved from rook-recovery-jobs/)
- `infrastructure/rook-ceph-cluster/servicemonitor.yaml` — ServiceMonitor for ceph mgr metrics
- `infrastructure/prometheus/rook-ceph-health.yaml` — PromRule with 9 alerts

### Files modified
- `infrastructure/rook-ceph-cluster/kustomization.yaml` — add `toolbox.yaml` + `servicemonitor.yaml` to resources
- `infrastructure/rook-ceph-cluster/cephcluster.yaml` — mon storage `10Gi` → `20Gi`; add `monitoring.enabled: true`
- `infrastructure/rook-recovery-jobs/README.md` — remove toolbox row; note it's Flux-managed now

### Files removed
- `infrastructure/rook-recovery-jobs/toolbox.yaml`

### Restore behavior after merge
On cold-start cluster:
1. Operator deploys
2. CephCluster CR applies → osd-prepare jobs find `/dev/sdb` on each worker
3. Mons get 20Gi PVCs (won't fill for weeks)
4. Mgr `monitoring.enabled: true` → mgr prometheus module exposes /metrics
5. ServiceMonitor scrapes ceph_* metrics into Prometheus
6. PromRule fires alerts on real degradation
7. Toolbox Deployment running always-on → any ad-hoc ceph CLI work just works

### Verification after merge
```bash
kubectl -n flux-system get kustomization rook-ceph-cluster
kubectl -n rook-ceph get deploy rook-ceph-tools                    # should exist
kubectl -n rook-ceph get servicemonitor                             # should exist
kubectl -n rook-ceph get prometheusrule -l team=rook                # should exist
kubectl -n rook-ceph get pvc | grep mon                             # should still show 10Gi (existing PVCs don't auto-expand — Phase 2 is a one-shot resize via kubectl patch pvc, see INFRA-1536)
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s         # should work without any manual setup
```

### Ticket
INFRA-1538 (parent) + INFRA-1532 (closed) + INFRA-1536 (mon PVC bump, partial close — IaC value updated; existing PVCs need INFRA-1536 follow-up to expand)

## PR-D — Cross-cluster ExternalSecret split (iaac-talos-flux-platform op-dev)

### Files added
- `infrastructure/cross-cluster-app-secrets/geoenrichment-sync-handler-m-u.yaml` — the ES (uncommented)
- `infrastructure/cross-cluster-app-secrets/kustomization.yaml`

### Files modified
- `infrastructure/app-secrets/geoenrichment-sync-handler.yaml` — remove the long ExternalSecret comment-block (the ES is now in cross-cluster-app-secrets/); keep Namespace + ConfigMap

### Restore behavior after merge
On cold-start cluster:
1. `cross-cluster-app-secrets` Kustomization Ready (wait: false) within seconds
2. ES applies, sits in `SecretSyncedError` because cloud-eks CSS isn't Ready (no token seed yet)
3. **NO manual intervention from operator beyond running the INFRA-1535 Octopus runbook**
4. When operator runs the runbook, token gets seeded, cloud-eks CSS goes Ready, ES auto-syncs on next refresh

### Verification after merge
```bash
kubectl -n flux-system get kustomization cross-cluster-app-secrets   # Ready=True
kubectl -n geoservices get externalsecret geoenrichment-sync-handler-m-u
# Status will be SecretSyncedError until INFRA-1535 runbook runs — that's expected
```

### Ticket
INFRA-1538 (parent) + INFRA-1535 (Octopus runbook, separate ticket)

## PR-E — Flux Kustomization updates (iaac-talos-flux-cluster master)

Companion to PR-C/PR-D. Must merge AFTER PR-D so the path exists when Kustomization reconciles.

### File modified
- `clusters/bm-dev/flux-system/infra.yaml` — see `flux-cluster/infra-yaml-PATCH.md`:
  - Flip `external-secrets-config` Kustomization `wait: false` → `wait: true`
  - Append new `cross-cluster-app-secrets` Kustomization (wait: false, dependsOn cross-cluster-eso + app-namespaces)

### Restore behavior after merge
Bootstrap chain becomes:
```
external-secrets ──┬─→ external-secrets-config (default CSS only, wait: true) ──→ app-secrets, octopus-worker
                   └─→ cross-cluster-eso (cloud-eks CSS, wait: false) ──→ cross-cluster-app-secrets (wait: false)
```

`wait: true` on external-secrets-config means downstream Kustomizations correctly block until default CSS is Ready. `wait: false` on the cross-cluster-* branch means the Octopus-runbook dependency never blocks bootstrap.

### Verification after merge
```bash
flux get kustomizations -A | awk 'NR==1 || $4!="True"'   # header only
kubectl -n flux-system get kustomization cross-cluster-app-secrets   # Ready=True
kubectl -n flux-system get kustomization external-secrets-config -o yaml | grep wait:    # wait: true
```

### Ticket
INFRA-1538 (parent)

## Merge order

1. **PR-C** (platform) → adds Rook IaC, no dependency on other PRs
2. **PR-D** (platform) → adds new directory `cross-cluster-app-secrets/`
3. **PR-E** (cluster) → adds Kustomization pointing at the new directory; flips wait flag

Wait ≥ 3 min between PR-D merge and PR-E merge for the GitRepository to pick up the new directory (or force-reconcile the source as we did today).

## Post-merge verification (all 3 PRs landed)

```bash
export KUBECONFIG=~/.kube/op-usxpress-dev.yaml

# All Kustomizations should be Ready=True
flux get kustomizations -A | awk 'NR==1 || $4!="True"'

# Rook IaC active
kubectl -n rook-ceph get deploy rook-ceph-tools
kubectl -n rook-ceph get servicemonitor
kubectl get prometheusrule -n rook-ceph rook-ceph-health

# Mon PVC IaC value updated (existing PVCs stay 10Gi until separate expand step)
kubectl -n flux-system get kustomization rook-ceph-cluster -o yaml | grep -A 2 "lastAppliedRevision"

# Cross-cluster app secrets present + expected SecretSyncedError
kubectl -n flux-system get kustomization cross-cluster-app-secrets
kubectl -n geoservices get externalsecret

# Cluster end-state — Tim's RW untouched
kubectl -n risingwave get pods | wc -l    # 15
kubectl -n risingwave-2 get pods | grep risingwave | wc -l
```

## What's NOT in these 3 PRs

- **Existing mon PVC expansion from 10Gi → 20Gi**: Local-path-provisioner does not support PVC expansion. The IaC change in PR-C only takes effect for NEW mon PVCs (e.g., on a cold-start cluster). Existing 10Gi PVCs require either (a) a kubectl-orchestrated mon-by-mon recreate, or (b) waiting for an OSD/mon redeploy. Tracked separately in INFRA-1536.
- **INFRA-1535 Octopus runbook**: Separate ticket. Cluster restore IS NOT FULLY HANDS-FREE until this exists. Documented as a one-time per-cluster manual step.
- **pod-identity-webhook caBundle auto-refresh** (INFRA-1537): Independent track.
- **argocd/argocd-admin-credentials ES error**: Investigated separately by Idris; not Rook-related.

# CephCluster monitoring.enabled flag causes operator RBAC stall on cold-start

## Symptom

- Cluster bootstrap: `rook-ceph-cluster` Flux Kustomization reconciles but operator stalls
- Operator logs:
  ```
  E | ceph-cluster-controller: failed to reconcile CephCluster "rook-ceph/rook-ceph":
    failed to start ceph mgr: failed to enable mgr services: failed to enable service monitor:
    servicemonitors.monitoring.coreos.com "rook-ceph-mgr" is forbidden:
    User "system:serviceaccount:rook-ceph:rook-ceph-system" cannot get resource "servicemonitors"
    in API group "monitoring.coreos.com" in the namespace "rook-ceph"
  ```
- Mons may NOT be created or recreated; CephCluster reconciliation hangs

## Root cause

`spec.monitoring.enabled: true` on the CephCluster CR makes the rook-ceph-operator attempt to manage a ServiceMonitor named `rook-ceph-mgr` in the `rook-ceph` namespace. The operator's ServiceAccount (`rook-ceph-system`) does NOT have RBAC for `servicemonitors.*` in `monitoring.coreos.com` API group. Reconciliation fails.

## Resolution

Two options:

### Option A (preferred): Omit `monitoring.enabled` from CephCluster CR

Manage the ServiceMonitor ourselves via separate IaC file in `infrastructure/rook-ceph-cluster/servicemonitor.yaml`. The operator does NOT need to manage it. Our SM has correct labels (`release: prometheus-stack`) for kube-prometheus-stack discovery.

```yaml
# DO NOT set this on CephCluster CR
# monitoring:
#   enabled: true
```

### Option B: Grant operator the servicemonitors RBAC

Patch the rook-ceph-operator ClusterRole to include:
```yaml
- apiGroups: ["monitoring.coreos.com"]
  resources: ["servicemonitors"]
  verbs: ["get", "list", "watch", "create", "update", "delete"]
```

This works but means two controllers fight over the SM resource. Option A is cleaner.

## How we hit this

Caught during 2026-06-22 mon-a recreate (INFRA-1536). PR #48 added `monitoring.enabled: true` to CephCluster CR. After PR merged + Flux reconciled, operator started erroring on every reconcile. Force-reconcile after mon-a delete eventually pushed through (operator got past the SM check by retrying mon work), but on a cold-start cluster the operator could stall indefinitely.

Fixed via PR #51 (removed `monitoring.enabled: true`).

## Detection

```bash
kubectl -n rook-ceph logs deploy/rook-ceph-operator --tail=200 | grep "servicemonitors.monitoring.coreos.com"
```

If any matches, the flag is set and operator is logging this error.

## Prevention

QA cluster bootstrap checklist: confirm CephCluster CR does NOT have `monitoring.enabled: true`. Confirm `infrastructure/rook-ceph-cluster/servicemonitor.yaml` exists with `release: prometheus-stack` label.

## Refs

- Catalog: [02-storage/rook-osd-keyring-missing.md](rook-osd-keyring-missing.md)
- IaC: `infrastructure/rook-ceph-cluster/cephcluster.yaml` (PR #51 removed the flag)
- IaC: `infrastructure/rook-ceph-cluster/servicemonitor.yaml` (PR #48 added)
- PromRule: `infrastructure/prometheus/rook-ceph-health.yaml` (PR #48 added, PR #49 fixed labels)

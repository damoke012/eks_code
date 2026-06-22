# Rook-Ceph Recovery Job Templates

**Status:** Manual-apply templates (NOT in any Flux Kustomization). Use these when troubleshooting catalog entries call for them.

> Note: `toolbox.yaml` was moved out of this directory on 2026-06-22 and is now Flux-managed
> via `infrastructure/rook-ceph-cluster/toolbox.yaml`. It runs always-on; you do not need
> to apply it manually.

## What lives here

| File | Purpose | Catalog ref |
|---|---|---|
| `osd-wipe.yaml` | Privileged Pod that zeroes `/dev/sdb` on the named node. Required step when re-bootstrapping an OSD with stale bluestore state. | [02-storage/rook-osd-keyring-missing.md](../../wip/onprem-troubleshooting/02-storage/rook-osd-keyring-missing.md), [02-storage/rook-osd-pg-peering-crash.md](../../wip/onprem-troubleshooting/02-storage/rook-osd-pg-peering-crash.md) |
| `bluestore-inspect.yaml` | Read-only privileged Pod that dumps `ceph-bluestore-tool show-label --dev /dev/sdb`. Used during diagnosis. | [02-storage/rook-osd-keyring-missing.md](../../wip/onprem-troubleshooting/02-storage/rook-osd-keyring-missing.md) |

## Apply

```bash
# Substitute <NODE> with the target worker hostname (talos-wk-op-dev-X)
sed 's/<NODE>/talos-wk-op-dev-2/g' osd-wipe.yaml | kubectl apply -f -

# Wait for completion
kubectl -n rook-ceph wait pod/osd-wipe-talos-wk-op-dev-2 --for=condition=Ready --timeout=30s
sleep 10
kubectl -n rook-ceph logs osd-wipe-talos-wk-op-dev-2

# Clean up
kubectl -n rook-ceph delete pod osd-wipe-talos-wk-op-dev-2
```

## Why these are not in Flux

- They're destructive (wipe disks)
- They're per-incident (not steady-state resources)
- Operator already has the safe steady-state OSD lifecycle in IaC (CephCluster CR + Rook operator)

These templates exist to be applied manually by an on-call engineer, with the catalog entry providing the decision tree for when to use them.

## Companion: toolbox

`rook-ceph-tools` (the always-on ceph CLI Deployment) was previously in this directory but is now Flux-managed at `infrastructure/rook-ceph-cluster/toolbox.yaml`. It is the supported path for `kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s` and any ad-hoc ceph CLI work.

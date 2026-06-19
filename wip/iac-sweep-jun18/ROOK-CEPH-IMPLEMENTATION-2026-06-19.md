# Rook-Ceph on op-usxpress-dev — Full Implementation Document

**Cluster:** op-usxpress-dev (Talos on-prem, 3 CPs + 7 workers, v1.32.0)
**Status:** Phase 1 + Phase 2 deployed; OSDs not yet spawning (mon crash-loop, separate failure mode)
**Owner:** Cloud Platform on-prem (Doke)
**Last updated:** 2026-06-19 (end of marathon session)

## Why Rook-Ceph

The cluster's default storage class is `local-path` (Rancher local-path-provisioner), which is single-node and not replicated. For production-grade workloads (Rook gives both block + filesystem + object), we need:

- **Replicated block** (`ceph-block`) — RWO with size=3 replicas across workers → no data loss on single worker failure
- **Filesystem** (`ceph-fs`) — RWX for workloads that need shared mounts
- **Object** (`ceph-bucket`) — S3-compatible for non-AWS workloads
- **On-prem self-contained** — no dependency on AWS S3 for cluster-internal state stores

This complements `local-path` (kept as default for ephemeral/local workloads) — Rook becomes the durable tier.

## Architecture

```
                     ┌─────────────────────────────┐
                     │   rook-ceph-operator (1)    │
                     │   namespace: rook-ceph      │
                     │   worker-only (nodeAffinity)│
                     └──────────────┬──────────────┘
                                    │ manages
                ┌───────────────────┼───────────────────┐
                ▼                   ▼                   ▼
       ┌────────────────┐  ┌────────────────┐  ┌─────────────────┐
       │  mons (3)      │  │  mgrs (2)      │  │  osds (7)       │
       │  PVC=local-path│  │  no PVC        │  │  device=/dev/sdb│
       │  workers       │  │  workers       │  │  workers        │
       └────────────────┘  └────────────────┘  └─────────────────┘
                │                   │                   │
                └─────────┬─────────┴─────────┬─────────┘
                          ▼                   ▼
                ┌───────────────────────────────────┐
                │   Ceph Cluster (replicapool)      │
                │   size=3 (3-way replication)      │
                │   ~115 GB usable / 350 GB raw     │
                └───────────────────────────────────┘
                          │
            ┌─────────────┼─────────────┐
            ▼             ▼             ▼
    ┌───────────┐ ┌──────────────┐ ┌──────────────┐
    │ ceph-block│ │   ceph-fs    │ │ ceph-bucket  │
    │ (RWO)     │ │   (RWX)      │ │ (S3 object)  │
    └───────────┘ └──────────────┘ └──────────────┘
```

### Component placement rules (per `[onprem-safety]` skill Rule 1)

- **All Rook pods (operator + mons + mgrs + osds + csi):** explicit `nodeAffinity` excludes `node-role.kubernetes.io/control-plane`
- **CSI plugin DaemonSets:** `csi.pluginTolerations: []` + `csi.pluginNodeAffinity: "node-role.kubernetes.io/control-plane=DoesNotExist"`
- **Mons:** local-path PVC per mon, hostPath-backed on worker node
- **OSDs:** raw block device `/dev/sdb` on worker (50 GB per worker × 7 = 350 GB raw)

### Storage classes produced

| StorageClass | Type | Provisioner | Use case |
|---|---|---|---|
| `ceph-block` | RWO | rook-ceph.rbd.csi.ceph.com | DB volumes, persistent state |
| `ceph-fs` | RWX | rook-ceph.cephfs.csi.ceph.com | Shared mounts (multiple pod readers) |
| `ceph-bucket` | S3 object | rook-ceph.ceph.rook.io/bucket | On-prem object storage (S3-compatible) |
| `local-path` (preserved default) | RWO local | rancher.io/local-path | Ephemeral / single-node workloads |

## Phased rollout plan

### Phase 1 — vSphere disk add (DONE — 2026-06-18)

**Source:** [`iaac-talos PR #37`](https://github.com/variant-inc/iaac-talos/pull/37) (merged + applied via Octopus 1.163)

What it did: added 2nd vSphere virtual disk (50 GB, `/dev/sdb`) to every worker VM in the worker pool. Idempotent for fresh deploys — the disk is part of the Terraform-managed VM resource.

```hcl
# iaac-talos/deploy/terraform/modules/vsphere_vm/main.tf
resource "vsphere_virtual_machine" "vm" {
  # ... existing config ...
  disk {
    label            = "disk1"  # /dev/sdb
    size             = 50
    eagerly_scrub    = false
    thin_provisioned = true
    unit_number      = 1
  }
}
```

Verified post-apply: `talosctl get disks` on every worker shows `sdb`.

### Phase 2 — CephCluster `deviceFilter` (DONE — 2026-06-18)

**Source:** [`iaac-talos-flux-platform PR #44`](https://github.com/variant-inc/iaac-talos-flux-platform/pull/44) (merged + Flux applied)

What it did: replaced the failed `storageClassDeviceSets`+`local-path` attempt with `deviceFilter: "^sdb$"` on the CephCluster CR. Operator now scans each worker for `/dev/sdb` and spawns 1 OSD per matching device.

File: `infrastructure/rook-ceph-cluster/cephcluster.yaml`

```yaml
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: rook-ceph
  namespace: rook-ceph
spec:
  cephVersion:
    image: quay.io/ceph/ceph:v18.2.4
    allowUnsupported: false
  dataDirHostPath: /var/lib/rook
  skipUpgradeChecks: false
  continueUpgradeAfterChecksEvenIfNotHealthy: false
  waitTimeoutForHealthyOSDInMinutes: 10
  mon:
    count: 3
    allowMultiplePerNode: false
    volumeClaimTemplate:
      spec:
        storageClassName: local-path
        resources:
          requests:
            storage: 10Gi
        accessModes: [ReadWriteOnce]
  mgr:
    count: 2
    allowMultiplePerNode: false
    modules:
      - name: pg_autoscaler
        enabled: true
  dashboard:
    enabled: true
    ssl: true
  monitoring:
    enabled: true
  network:
    connections:
      encryption: { enabled: false }
      compression: { enabled: false }
  crashCollector:
    disable: false
  storage:
    useAllNodes: true
    useAllDevices: false
    deviceFilter: "^sdb$"           # Phase 2 — matches the disk from Phase 1
    config:
      osdsPerDevice: "1"            # 1 OSD per disk → 7 OSDs total
  placement:
    all:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
                - key: node-role.kubernetes.io/control-plane
                  operator: DoesNotExist
      tolerations: []
  disruptionManagement:
    managePodBudgets: true
    osdMaintenanceTimeout: 30
```

### Phase 3 — Observability + monitoring (PENDING)

**Tracked in:** `wip/iac-sweep-jun18/track2-rook-ceph-observability/` (drafted)
**Gated on:** Phase 2 OSDs actually spawning + healthy mon quorum

Components needed:

1. **PrometheusRule** for ceph health:
   - `CephClusterHealthWarn` — CephCluster CR phase != Ready
   - `CephOSDDown` — any OSD reports down for > 5 min
   - `CephMonDown` — < 2 of 3 mons reachable (quorum loss imminent)
   - `CephSlowOps` — slow ops on any OSD
   - `CephStorageNearFull` — pool > 80% used

2. **ServiceMonitor** for Rook metrics (Prometheus scrapes ceph-mgr exporter on :9283)

3. **Grafana dashboards** — import official Ceph dashboards (1029, 5336, 7056)

4. **Restore runbook** — how to recover from:
   - Total mon loss (3/3 down)
   - OSD failure (1 OSD = data still safe with size=3)
   - Cluster-wide corruption (restore from etcd snapshot + Rook re-import)

### Phase 4 — Production readiness (FUTURE)

- Backup of CephCluster state to S3 (off-cluster)
- Cross-cluster disaster recovery test
- Capacity planning (when to add more disks / workers)
- Upgrade procedure (Ceph version bumps)

## Current state at session end (2026-06-19 ~02:20)

| Component | State |
|---|---|
| Phase 1 vSphere disks | ✓ all 7 workers have `/dev/sdb` (50 GB) |
| Phase 2 CephCluster CR | ✓ Live with `deviceFilter: ^sdb$` |
| rook-ceph-operator pod | Was Pending earlier in session; may need re-check |
| mons (a, b, c) | ⚠ Crash-looping (pre-existing 10h+ before this session, separate failure domain) |
| OSDs | ❌ Not yet spawning — blocked on mon health |
| StorageClasses (ceph-block / -fs / -bucket) | ❌ Not yet created — depends on healthy cluster |
| Phase 3 observability | DRAFT in `track2-rook-ceph-observability/`, not PRed |

## Known blockers (carried into next session)

### Mon crash loop (pre-existing)

- `rook-ceph-mon-a` / `rook-ceph-mon-b` / `rook-ceph-mon-c` — restart counts 15-16 each
- Operator pod was `Pending` earlier (memory pressure on workers — now resolved with 12 GB bump)

**Recovery path next session:**
1. Diagnose mon logs (`kubectl logs rook-ceph-mon-a-*`) — probably PVC volume issue or mon DB corruption
2. Check operator pod state — should now schedule with 12 GB workers
3. If mon-endpoints ConfigMap stuck pending-deletion: force-remove finalizer
4. Once mon quorum back: OSDs spawn within ~5 min from existing CR

### Stuck mon-endpoints ConfigMap

- ConfigMap `rook-ceph-mon-endpoints` has `deletionTimestamp: 2026-06-17T16:22:04Z` + finalizer `ceph.rook.io/disaster-protection`
- Blocks operator from recreating fresh mon endpoints

**Recovery:**
```bash
kubectl -n rook-ceph patch configmap rook-ceph-mon-endpoints \
  -p '{"metadata":{"finalizers":null}}' --type=merge
```

## Repository + file inventory

### iaac-talos (Terraform — VM + Talos config)

- `deploy/terraform/modules/vsphere_vm/main.tf` — Phase 1 disk added here
- `deploy/terraform/variables.tf` — `worker_memory_mb` default 12288 (PR #40)
- Branch: `feature/op-usxpress-dev` (current cluster source)

### iaac-talos-flux-platform (Flux — operator + cluster CR)

- `infrastructure/rook-ceph-operator/` — operator HelmRelease + values
- `infrastructure/rook-ceph-cluster/` — CephCluster CR + storage classes
  - `cephcluster.yaml` — Phase 2 deviceFilter change
- Branch: `op-dev`

### iaac-talos-flux-cluster (Flux — cluster bootstrap)

- `clusters/bm-dev/flux-system/infra.yaml` — Kustomization for rook-ceph-operator and rook-ceph-cluster
- Branch: `master`

### WIP drafts (not yet PRed)

- `wip/iac-sweep-jun18/rook-ceph-phase1-vsphere-disk-add.md` — Phase 1 details
- `wip/iac-sweep-jun18/rook-ceph-phase2-deviceFilter.md` — Phase 2 PR draft
- `wip/iac-sweep-jun18/track2-rook-ceph-observability/` — Phase 3 PromRule + ServiceMonitor drafts

## Memory pointers (background context)

- `memory/risingwave_onprem_progress.md` — earlier on-prem storage experiments
- `memory/onprem_external_access_l2_vs_nodeport.md` — networking constraints affecting Rook dashboard exposure
- `memory/vibin_decisions_march31.md` — original decision to pursue Rook-Ceph after AHV
- `memory/session_state_jun18_pm.md` — Phase 1 disk add session
- `memory/session_state_jun19_late.md` — Phase 2 live but mons blocked

## Official Rook-Ceph references

- Rook docs: https://rook.io/docs/rook/latest-release/
- CephCluster CR ref: https://rook.io/docs/rook/latest-release/CRDs/Cluster/ceph-cluster-crd/
- `deviceFilter` config: https://rook.io/docs/rook/latest-release/CRDs/Cluster/host-cluster/
- Mon recovery: https://rook.io/docs/rook/latest-release/Storage-Configuration/Advanced/ceph-mon-health/
- Disaster recovery: https://rook.io/docs/rook/latest-release/Troubleshooting/disaster-recovery/

## How fresh cluster bring-up handles this

For a brand-new cluster (QA, PROD, or rebuild of dev):

1. **Talos cluster + Flux bootstrap** brings up via iaac-talos Terraform → cluster running, Flux installed
2. **First Flux reconcile** sees `clusters/<env>/flux-system/infra.yaml`, applies rook-ceph-operator + rook-ceph-cluster Kustomizations
3. **rook-ceph-operator HelmRelease** lands, operator pod starts on a worker (per nodeAffinity)
4. **CephCluster CR** applied (with `deviceFilter: ^sdb$`)
5. **Operator scans nodes** for `/dev/sdb`, finds it on every worker (Phase 1 ensures this)
6. **mons** scheduled with local-path PVCs (3 mons across 3 workers)
7. **mgrs** scheduled (2 across workers)
8. **OSDs** prepared per worker — 1 OSD per matching device
9. **Cluster reaches HEALTH_OK** typically within 5-10 min
10. **StorageClasses** created (ceph-block, ceph-fs, ceph-bucket) — usable by any workload

No manual intervention required IF:
- Phase 1 disk add is in the VM module (✓ since PR #37 merged)
- Phase 2 CR is in flux-platform (✓ since PR #44 merged)
- Worker memory ≥ 8 GB per node (✓ since PR #39 + #40 bumped to 12 GB)
- Phase 3 monitoring exists (PENDING — drafts in track2)

## What's IaC'd vs manual today

| Need | IaC'd? |
|---|---|
| 2nd disk per worker | ✓ PR #37 (iaac-talos) |
| CephCluster CR | ✓ PR #44 (flux-platform op-dev) |
| Worker placement (avoid CPs) | ✓ in cephcluster.yaml |
| Storage classes (ceph-*) | ✓ created by operator from CR |
| Worker RAM ≥ 12 GB | ✓ PR #40 (iaac-talos) |
| Mon crash-loop diagnosis runbook | ❌ — needs writing |
| Stuck finalizer recovery runbook | ❌ — needs writing (one-liner pattern documented above) |
| PromRules for ceph health | ❌ — drafted in track2, not PRed |
| ServiceMonitor for ceph metrics | ❌ — drafted in track2, not PRed |
| Grafana dashboards | ❌ — Phase 3 |
| Backup/DR | ❌ — Phase 4 |

## Next session work

In order:

1. **Diagnose + recover mons** (manual, then codify the recovery in a runbook)
2. **Watch OSDs spawn** once mons quorum back
3. **Ship Phase 3 PRs** (PromRule + ServiceMonitor + Grafana imports)
4. **Codify recovery runbook** (mon restart, finalizer removal, operator re-kick)
5. **Smoke test** a PVC with `storageClassName: ceph-block` from any namespace
6. **Plan Phase 4** (DR, backup, capacity planning)

## Cross-references

- `INCIDENT-COVERAGE-MATRIX-2026-06-19.md` — tonight's incident IaC coverage
- `STATE.md` — overall WIP status
- `rook-ceph-phase2-deviceFilter.md` — Phase 2 PR description (now applied)

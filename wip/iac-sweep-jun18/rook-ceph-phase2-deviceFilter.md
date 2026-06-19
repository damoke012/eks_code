# Rook-Ceph Phase 2 — switch CephCluster to deviceFilter (DRAFT)

**Target repo:** iaac-talos-flux-platform (branch `op-dev`)
**Branch:** `feature/INFRA-???-cephcluster-deviceFilter`
**Status:** DRAFT — NOT YET PRed. Gated on Phase 1 (the 2nd disks must exist before this lands).

## Why

Phase 1 added `/dev/sdb` to each worker. This PR switches Rook from the failing `storageClassDeviceSets` + local-path approach to directly consuming raw block devices via `deviceFilter`.

## What changes

### `infrastructure/rook-ceph-cluster/cephcluster.yaml`

Replace the `storage` block. From:

```yaml
spec:
  storage:
    storageClassDeviceSets:
      - name: set1
        count: 3
        portable: false
        encrypted: false
        placement:
          podAntiAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
              - labelSelector: ...
                topologyKey: kubernetes.io/hostname
          # ...
        preparePlacement: ...
        resources:
          requests: { cpu: 250m, memory: 1Gi }
          limits:   { cpu: 1000m, memory: 2Gi }
        volumeClaimTemplates:
          - metadata:
              name: data
            spec:
              resources: { requests: { storage: 50Gi } }
              storageClassName: local-path
              volumeMode: Filesystem    # broken — local-path doesn't support Block, Rook requires Block
              accessModes: [ReadWriteOnce]
    useAllNodes: false
    useAllDevices: false
```

To:

```yaml
spec:
  storage:
    useAllNodes: true
    useAllDevices: false
    deviceFilter: "^sdb$"        # matches the Phase 1 disk
    config:
      osdsPerDevice: "1"         # one OSD per disk
```

Keep placement block (worker-only):

```yaml
spec:
  placement:
    all:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
                - key: node-role.kubernetes.io/control-plane
                  operator: DoesNotExist
      tolerations: []
```

Mon spec stays as-is (mons keep using local-path PVCs — that's the standard Rook pattern).

## After merge — operator reconciliation

Flux will reconcile the CR. The operator will:

1. Tear down failing OSD prepare jobs (they were trying to use the deleted local-path PVCs)
2. Scan each worker for devices matching `^sdb$`
3. Create one OSD per matching device → 7 OSDs across 7 workers
4. CephCluster phase: Progressing → Ready, HEALTH_WARN → HEALTH_OK within ~5 min

## How to verify

```bash
# 1. CR has the new storage spec
kubectl -n rook-ceph get cephcluster -o jsonpath='{.spec.storage}'

# 2. OSD prepare pods run + complete (no more Init:0/2 stalls)
kubectl -n rook-ceph get pods -l app=rook-ceph-osd-prepare

# 3. OSD pods come up
kubectl -n rook-ceph get pods -l app=rook-ceph-osd -o wide
# Expect 7 OSDs Running, one per worker

# 4. CephCluster healthy
kubectl -n rook-ceph get cephcluster
# PHASE=Ready, HEALTH=HEALTH_OK

# 5. StorageClasses available
kubectl get sc
# Expect: ceph-block, ceph-fs, ceph-bucket (in ADDITION to local-path)
```

## Smoke test

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ceph-smoke-test
  namespace: default
spec:
  storageClassName: ceph-block
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
```

```bash
kubectl apply -f -  # the YAML above
kubectl get pvc ceph-smoke-test
# Expect: Bound within 30s
kubectl delete pvc ceph-smoke-test   # cleanup
```

## Cluster impact

- Zero disruption to existing PVCs (local-path consumers untouched)
- Zero disruption to mons (still on local-path)
- Brief reconcile churn in rook-ceph namespace as old PVCs/jobs clean up + new OSDs spawn
- After: Ceph PVCs become available as a NEW option — nothing existing changes class

## Risks

- **`deviceFilter` syntax wrong** — if Talos sees the new disk as `/dev/nvme1n1` instead of `/dev/sdb`, the filter matches nothing. Phase 1 must verify the actual device name first.
- **`osdsPerDevice` count** — default is 1; with thin-provisioned 50 GB disks, 1 OSD each = 7 OSDs total = 350 GB raw, ~115 GB usable (replicapool size=3).
- **mon PVCs still local-path** — if a worker hosting a mon dies, that mon's data is lost (other 2 mons keep quorum; lost mon re-bootstraps from cluster info)

## Cleanup post-merge

```bash
# Delete stale failing PVCs from prior approach
kubectl -n rook-ceph delete pvc -l ceph.rook.io/DeviceSet=set1 --ignore-not-found

# Delete stale OSD prepare jobs
kubectl -n rook-ceph delete jobs -l app=rook-ceph-osd-prepare --ignore-not-found

# (Operator will recreate the right Jobs as part of reconcile)
```

## Phase 3 follow-on

After Phase 2 lands and OSDs are healthy, ship Track 2 Rook observability PRs from
`wip/iac-sweep-jun18/track2-rook-ceph-observability/`.

## Related
- [[rook_ceph_production_plan_jun18]] — full plan
- `wip/iac-sweep-jun18/rook-ceph-phase1-vsphere-disk-add.md` — gating Phase 1
- `wip/iac-sweep-jun18/track2-rook-ceph-observability/` — gated on this Phase

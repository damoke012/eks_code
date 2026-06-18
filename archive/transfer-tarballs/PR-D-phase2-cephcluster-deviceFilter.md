# PR D — Phase 2: switch cephcluster.yaml to deviceFilter

**Target repo:** iaac-talos-flux-platform
**Base branch:** op-dev
**Branch:** feature/INFRA-XXXX-cephcluster-deviceFilter

## What changes

Find `infrastructure/rook-ceph-cluster/cephcluster.yaml` on WSL (or equivalent path; the file is the CephCluster CR that Flux applies).

### Replace the `spec.storage` block

REMOVE the existing `storageClassDeviceSets` block (it was the failed local-path attempt). It looks roughly like:

```yaml
spec:
  storage:
    storageClassDeviceSets:
      - name: set1
        count: 3
        portable: false
        encrypted: false
        placement: ...
        preparePlacement: ...
        resources: ...
        volumeClaimTemplates:
          - metadata:
              name: data
            spec:
              resources: { requests: { storage: 50Gi } }
              storageClassName: local-path
              volumeMode: Filesystem
              accessModes: [ReadWriteOnce]
    useAllNodes: false
    useAllDevices: false
```

REPLACE with:

```yaml
spec:
  storage:
    useAllNodes: true
    useAllDevices: false
    deviceFilter: "^sdb$"            # matches the Phase 1 disk on all 7 workers
    config:
      osdsPerDevice: "1"             # 1 OSD per disk → 7 OSDs total → ~115 GB usable (size=3)
```

### Keep the `spec.placement` block UNCHANGED (worker-only)

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

Mon spec (using local-path PVCs) stays as-is — standard Rook pattern is mons on local-path, OSDs on dedicated disks.

## How to find + edit on WSL

```bash
cd ~/work/iaac-talos-flux-platform
git fetch origin op-dev
git checkout op-dev
git pull origin op-dev
git checkout -b feature/INFRA-XXXX-cephcluster-deviceFilter

# Find the CR file
find infrastructure -name "cephcluster*.yaml" -o -name "rook*cluster*.yaml" 2>/dev/null

# Open it in your editor and make the swap shown above
# (the existing block is multi-line; safest with an editor not sed)
```

After edit:

```bash
git diff --stat   # expect: 1 file changed, ~20 lines removed, ~5 lines added
git diff          # verify ONLY the storage block changed

git add infrastructure/rook-ceph-cluster/cephcluster.yaml   # (or actual path)
git commit -m "feat(rook): switch CephCluster to deviceFilter ^sdb$

Phase 2 of the Rook-Ceph rollout. Phase 1 (iaac-talos PR #37) added
a 2nd raw disk (/dev/sdb, 50 GB) to every worker. This PR switches
the CephCluster CR from the broken storageClassDeviceSets+local-path
approach to deviceFilter, which directly consumes the raw block
device on each worker for OSDs.

Effects on Flux reconcile:
- Operator tears down failing OSD prepare jobs (were targeting
  the deleted set1-data-* PVCs)
- Operator scans each worker for /dev/sdb (deviceFilter ^sdb\$)
- Creates 1 OSD per matching device = 7 OSDs across 7 workers
- ~350 GB raw, ~115 GB usable (replicapool size=3)
- CephCluster phase: Progressing → Ready, HEALTH_WARN → HEALTH_OK within ~5 min

Adds NEW StorageClasses (ceph-block, ceph-fs, ceph-bucket) as
ADDITIONAL options. local-path stays the default; existing Grafana,
RW, Postgres, prometheus, mon PVCs are PRESERVED.

Pattern carries to QA + PROD with same CR (deviceFilter is
cluster-agnostic)."

git push -u origin feature/INFRA-XXXX-cephcluster-deviceFilter

gh pr create \
  --base op-dev \
  --title "feat(rook): Phase 2 — CephCluster deviceFilter ^sdb\$" \
  --body "Phase 2 of Rook rollout. Replaces broken storageClassDeviceSets+local-path block with deviceFilter ^sdb\$. Each worker has the disk from Phase 1 (iaac-talos #37 + Octopus 1.163). Expect: 7 OSDs spawn, HEALTH_OK ~5 min, new StorageClasses ceph-block/ceph-fs/ceph-bucket become available."
```

## Post-merge verify (after Flux reconciles, ~5-10 min)

```bash
KCONFIG="--server=https://10.10.82.179:6443 --insecure-skip-tls-verify=true"

# 1. Old set1 PVCs cleaned up
kubectl $KCONFIG -n rook-ceph delete pvc -l ceph.rook.io/DeviceSet=set1 --ignore-not-found
kubectl $KCONFIG -n rook-ceph delete jobs -l app=rook-ceph-osd-prepare --ignore-not-found

# 2. Operator force-reconcile (Flux already triggers, but to speed up)
kubectl $KCONFIG -n rook-ceph rollout restart deploy rook-ceph-operator

# 3. Watch OSDs come up (~5 min)
kubectl $KCONFIG -n rook-ceph get pods -l app=rook-ceph-osd-prepare -w
# Then:
kubectl $KCONFIG -n rook-ceph get pods -l app=rook-ceph-osd -o wide

# 4. CephCluster status
kubectl $KCONFIG -n rook-ceph get cephcluster
# Want: PHASE=Ready, HEALTH=HEALTH_OK

# 5. New StorageClasses
kubectl $KCONFIG get sc
# Should see: ceph-block, ceph-fs, ceph-bucket (alongside local-path)
```

## Smoke test (any namespace)

```bash
cat <<EOF | kubectl $KCONFIG apply -f -
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
EOF
kubectl $KCONFIG get pvc ceph-smoke-test
# Want: Bound within 30s
kubectl $KCONFIG delete pvc ceph-smoke-test
```

## Risks

- If `/dev/sdb` happens to come up as `/dev/nvme1n1` on some workers (depends on vSphere controller — unlikely for our pvscsi setup, but possible), the deviceFilter matches nothing on those workers and you'd get fewer OSDs. Phase 1 verify already showed `sdb` on all 7 workers ✓.
- If Flux Kustomization for rook-ceph has `prune: true`, removing fields could cascade. The change here is to `spec.storage` BLOCK content only — no resources deleted via prune.

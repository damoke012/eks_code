# INFRA-1532 — Rook-Ceph Storage Platform Deploy

Dev-first shippable bundle. NO talosconfig needed. NO Talos extensions needed. NO reboots.
QA/PROD will swap to a 2nd vSphere disk (separate iaac-talos PR) and bypass `local-path`.

## What ships

| Component | Where | Why |
|---|---|---|
| `rook-ceph` namespace (PSS: privileged) | `iaac-talos-flux-platform op-dev` → `infrastructure/rook-ceph/namespace.yaml` | Ceph daemons need privileged + raw block via CSI |
| `HelmRepository` (rook.io charts) | `infrastructure/rook-ceph/helmrepository.yaml` | Source for `rook-ceph` chart |
| `HelmRelease` rook-ceph operator (v1.15.5) | `infrastructure/rook-ceph/operator-helmrelease.yaml` + `operator-values-configmap.yaml` | Watches the cluster, runs CSI |
| `CephCluster` CR (mon=3, mgr=2, osd=3 PVC-on-local-path) | `infrastructure/rook-ceph/cephcluster.yaml` | The actual storage cluster |
| `CephBlockPool replicapool` (size=3, host failure domain) | `infrastructure/rook-ceph/storageclasses.yaml` | Backing pool for RBD |
| `StorageClass ceph-block` (RBD, RWO, xfs, expand=true) | `infrastructure/rook-ceph/storageclasses.yaml` | Target SC for Mimir, Grafana, etc |
| `CephFilesystem cephfs` + `StorageClass ceph-fs` (RWX) | `infrastructure/rook-ceph/storageclasses.yaml` | Shared file mounts |
| `CephObjectStore object-store` + `StorageClass ceph-bucket` (S3 via RGW) | `infrastructure/rook-ceph/storageclasses.yaml` | LGTM stack object backend |
| Flux Kustomization CR for `rook-ceph` | `iaac-talos-flux-cluster master` → `clusters/bm-dev/flux-system/infra.yaml` (appended) | Reconciles the platform module |

## Why PVC-on-local-path, not raw disks?

Workers are vSphere VMs with a single root disk (per `iaac-talos/deploy/terraform/modules/vsphere_vm`). No spare disks. Rook-Ceph 1.13+ deprecated directory OSDs. The PVC-based OSD pattern (`storageClassDeviceSets`) is the modern equivalent:

1. CephCluster requests a PVC of 50Gi `local-path` `volumeMode: Block`
2. local-path provisioner carves a dir under `/opt/local-path-provisioner/<uid>` on the chosen worker
3. Rook builds a BlueStore OSD on top of that path
4. 3 OSDs across 3 different workers (host anti-affinity) → replication=3 with failure domain=host

**Performance/durability tradeoff for dev:**
- ~30-50% raw-disk perf (file-on-fs overhead)
- Lose a worker = lose an OSD (Ceph rebuilds from the other two)
- Lose 2 workers = data unavailable until at least one recovers
- Single-disk failure domain per OSD: no separate WAL/DB

QA/PROD path (next iaac-talos PR): add `vsphere_worker.data_disk_gb` variable, attach a 2nd disk, rolling reboot one worker at a time during Tim's window, switch CephCluster to raw devices.

## Pre-merge checklist

```bash
# 1. Confirm local-path SC is healthy
kubectl get sc local-path
kubectl get pod -n local-path-storage  # rancher.io/local-path provisioner running

# 2. Confirm cilium-lb / Istio not blocking egress to charts.rook.io
curl -sI https://charts.rook.io/release/index.yaml | head -3

# 3. Confirm rook-ceph namespace doesn't already exist
kubectl get ns rook-ceph

# 4. Confirm flux infra source up to date
flux get source git infra -n flux-system

# 5. Confirm worker capacity. Each OSD wants 4Gi limit + 50Gi disk.
#    Three OSDs = 12Gi RAM across 3 workers + 150Gi disk consumed.
kubectl describe node | grep -E "^(Name|  cpu|  memory)" | head -30
df -h on each worker (via talos / node-shell) for /var/lib/rancher and /opt/local-path-provisioner
```

## Apply order

### Phase 1 — operator & cluster (this PR set)

1. **Platform PR** (iaac-talos-flux-platform op-dev): merge `infrastructure/rook-ceph/*`
2. **Cluster PR** (iaac-talos-flux-cluster master): append Flux Kustomization to `infra.yaml`
3. Wait for Flux to reconcile (or force):
   ```bash
   flux reconcile source git infra -n flux-system
   flux reconcile kustomization flux-system
   flux reconcile kustomization rook-ceph -n flux-system
   ```
4. Watch the bring-up (operator → CRDs → cluster → mons → osd-prepare → osds):
   ```bash
   kubectl -n rook-ceph get pods -w
   ```
   Expected timeline:
   - 0-2 min: rook-ceph-operator pod Running
   - 2-5 min: rook-ceph-mon-{a,b,c} pods Running (3 PVCs bound to local-path)
   - 5-8 min: rook-ceph-mgr-{a,b} pods Running
   - 5-10 min: rook-ceph-osd-prepare-* jobs run, then rook-ceph-osd-{0,1,2} pods Running
   - 8-12 min: rook-ceph-rgw + cephfs MDS pods Running

### Phase 2 — flip dependsOn (separate one-line PR)

Once the cluster reports HEALTH_OK consistently, edit the Flux Kustomization in `infra.yaml`:
- `spec.wait: false` → `true`
- Add `rook-ceph` to `dependsOn` of `grafana`, future `mimir`, `loki`, `tempo` Kustomizations

## Post-deploy validation

```bash
# 1. CephCluster Ready
kubectl -n rook-ceph get cephcluster
# Expected: PHASE=Ready, HEALTH=HEALTH_OK

# 2. All daemons Running
kubectl -n rook-ceph get pods -o wide
# Expect: 3 mon, 2 mgr, 3 osd, 1 rgw×2, 1 mds (cephfs), all Running

# 3. StorageClasses present
kubectl get sc | grep ceph
# Expect: ceph-block, ceph-fs, ceph-bucket

# 4. Test PVC binds on ceph-block (full RWO block path)
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ceph-smoke-test
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ceph-block
  resources:
    requests:
      storage: 1Gi
EOF
kubectl get pvc ceph-smoke-test
# Expect: STATUS=Bound within 60s
kubectl delete pvc ceph-smoke-test

# 5. Get the Ceph status via tools pod
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
# Expect: health: HEALTH_OK; 3 osds up,in; 3 mons quorum

# 6. Check object store has an endpoint
kubectl -n rook-ceph get cephobjectstore object-store -o jsonpath='{.status.info.endpoint}'

# 7. Dashboard (optional)
kubectl -n rook-ceph port-forward svc/rook-ceph-mgr-dashboard 7000:7000
# Login: admin / `kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath='{.data.password}' | base64 -d`
```

## RW protection

This deploy touches ONLY:
- new `rook-ceph` namespace
- new files in `infrastructure/rook-ceph/`
- new line in `clusters/bm-dev/flux-system/infra.yaml`

**Touches NOTHING in `risingwave` namespace.** RW services, pods, secrets, PVCs all untouched. CephCluster topology uses `node-role.kubernetes.io/control-plane: DoesNotExist` so no scheduling on CP; uses `podAntiAffinity` so OSDs spread across workers (don't pile up on the worker hosting RW frontend).

Pre/post smoke for Tim's RW:
```bash
# Before:
kubectl -n risingwave get cephcluster -o yaml > /tmp/pre-rw.yaml 2>/dev/null
kubectl -n risingwave get pods,svc,pvc > /tmp/pre-rw-state.txt
psql -h rw2-sql.op-dev.usxpress.io -p 5432 -U <user> -c "SELECT 1" > /tmp/pre-rw-psql.txt

# Bring up Rook-Ceph...

# After:
kubectl -n risingwave get pods,svc,pvc > /tmp/post-rw-state.txt
diff /tmp/pre-rw-state.txt /tmp/post-rw-state.txt  # should be empty
psql -h rw2-sql.op-dev.usxpress.io -p 5432 -U <user> -c "SELECT 1"  # should succeed
```

If anything regresses:
```bash
flux suspend kustomization rook-ceph -n flux-system
kubectl -n rook-ceph delete cephcluster rook-ceph --wait=false
# Operator + CRDs stay; cluster + StorageClasses cleared. RW unaffected.
```

## QA/PROD propagation (future)

Differences from dev (capture in QA PR's DEPLOY-README):
1. Add 2nd vSphere disk via `vsphere_worker` module (new `data_disk_gb` variable, default 100)
2. Talos install extensions: `siderolabs/util-linux-tools` + `siderolabs/iscsi-tools`
3. Rolling worker reboot (1 at a time, drain first, RW protection between each)
4. CephCluster: replace `storageClassDeviceSets` with `useAllNodes: true` + `useAllDevices: false` + `deviceFilter: "^sdb$"`
5. Increase `count: 3 → 7` (one OSD per worker, full topology)
6. Switch failure domain to `zone` once we have multi-rack/multi-DC

The rest of the manifest set (operator, pools, SCs) is IDENTICAL — same IaC, just topology values differ.

## Follow-up PRs (not in this bundle)

- Switch Grafana `persistence.storageClassName: local-path` → `ceph-block` after Ceph healthy (one-line PR + delete-and-rebind on Grafana PVC, requires brief downtime)
- Mimir HelmRelease using `ceph-bucket` for blocks, `ceph-block` for ingester WAL
- Loki HelmRelease using `ceph-bucket` for chunks
- Tempo HelmRelease using `ceph-bucket` for traces
- VirtualService for ceph dashboard at `ceph.op-dev.usxpress.io`
- ServiceMonitor for Ceph metrics into Prometheus
- AAD SSO on the dashboard once we have the LGTM stack hostnames in IT's app-reg list

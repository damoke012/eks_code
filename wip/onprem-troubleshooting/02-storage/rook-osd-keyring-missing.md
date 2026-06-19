# Rook-Ceph OSDs CrashLoop — Missing Keyring Secrets

**Symptom:**
- `kubectl -n rook-ceph get pods -l app=rook-ceph-osd` shows all 7 OSDs in `CrashLoopBackOff` (1/2 containers Running)
- OSD logs show:
  ```
  debug ... monclient(hunting): handle_auth_bad_method server allowed_methods [2] but i only support [2]
  failed to fetch mon config (--no-mon-config to skip)
  ```
- `kubectl -n rook-ceph get secrets | grep -E "rook-ceph-osd.*keyring"` returns NOTHING (no OSD keyring secrets exist)
- Other Rook component keyrings DO exist (`rook-ceph-mds-*-keyring`, `rook-ceph-mgr-*-keyring`)
- `kubectl -n rook-ceph get cephcluster` shows `PHASE=Ready, HEALTH=HEALTH_WARN`
- `osd-prepare` jobs complete in seconds (4-5s) — too fast for normal prepare, indicating they just verified existing bluestore data and exited without creating fresh auth

**Root cause:**
Rook's OSD design has the cephx keyring split between two places:
1. **Mon's auth database** — `ceph auth list` shows `osd.0`, `osd.1`, etc. with their keys
2. **Kubernetes Secret** — `rook-ceph-osd-X-keyring` mounted into the OSD pod at `/var/lib/ceph/osd/ceph-X/keyring`

If the k8s Secrets are missing but mons still have OSD auth entries, the OSD pod has nothing to read for its identity. It boots, attempts cephx auth with empty/missing key, mons reject it with `handle_auth_bad_method`.

This can happen when:
- A previous mon CR bootstrap was incomplete (mons created auth entries, but pod-secret creation step failed)
- Someone deleted the secrets directly thinking they were "stale"
- A Rook operator restart during incomplete bootstrap left mismatched state

**IaC coverage:** ⚠ (CephCluster CR is correct; recovery requires Rook DR procedure)

**IaC location:**
- `iaac-talos-flux-platform/infrastructure/rook-ceph-cluster/cephcluster.yaml` — CR is fine
- Recovery is operational, not codifiable as a single IaC change

### Resolution via IaC

For fresh clusters: this issue doesn't recur. The operator creates keyrings during normal bootstrap. The bug surfaces only when bootstrap was disrupted (see [[rook-operator-restart-state-loss]]).

### Manual resolution — Option A (preferred): extract keys from mons + recreate secrets

PRE-REQUISITE: mons must be healthy and reachable. Test with:

```bash
KCONFIG="--server=https://10.10.82.179:6443 --insecure-skip-tls-verify=true"

# Confirm operator can reach mons
kubectl $KCONFIG -n rook-ceph exec deploy/rook-ceph-operator -- ceph -s 2>&1 | head
# Want: cluster info, mon quorum
```

If `ceph -s` works:

```bash
# 1. List OSD auth entries
kubectl $KCONFIG -n rook-ceph exec deploy/rook-ceph-operator -- ceph auth list 2>&1 | grep -A 4 "^osd\."

# 2. For each OSD ID, extract key + create matching k8s Secret
for i in 0 1 2 3 4 5 6; do
  KEY=$(kubectl $KCONFIG -n rook-ceph exec deploy/rook-ceph-operator -- \
    ceph auth print-key osd.$i 2>/dev/null)
  
  # Create the keyring file content
  KEYRING="[osd.$i]
        key = $KEY
        caps mgr = \"allow profile osd\"
        caps mon = \"allow profile osd\"
        caps osd = \"allow *\""
  
  # Create the k8s Secret
  kubectl $KCONFIG -n rook-ceph create secret generic rook-ceph-osd-$i-keyring \
    --from-literal=keyring="$KEYRING" \
    --type=kubernetes.io/rook
done

# 3. Restart OSD pods to pick up new keyrings
kubectl $KCONFIG -n rook-ceph delete pods -l app=rook-ceph-osd

# 4. Watch OSDs come up
sleep 60
kubectl $KCONFIG -n rook-ceph get pods -l app=rook-ceph-osd
```

### Manual resolution — Option B: nuclear (wipe + re-bootstrap OSDs)

Use this if Option A doesn't work OR there's no real data to lose (e.g., bringup phase).

```bash
# 1. Remove OSD auth from mons
for i in 0 1 2 3 4 5 6; do
  kubectl $KCONFIG -n rook-ceph exec deploy/rook-ceph-operator -- \
    ceph auth del osd.$i
done

# 2. Remove OSDs from CRUSH map
for i in 0 1 2 3 4 5 6; do
  kubectl $KCONFIG -n rook-ceph exec deploy/rook-ceph-operator -- \
    ceph osd out osd.$i
  kubectl $KCONFIG -n rook-ceph exec deploy/rook-ceph-operator -- \
    ceph osd purge osd.$i --yes-i-really-mean-it
done

# 3. Wipe /dev/sdb on each worker (DESTRUCTIVE — no data on OSDs anyway)
export TALOSCONFIG=/tmp/talosconfig-op-usxpress-dev
for ip in 10.10.82.26 10.10.82.28 10.10.82.178 10.10.82.180 10.10.82.27 10.10.82.22 10.10.82.21; do
  # talosctl doesn't expose direct disk wipe — use machine config patch or reset disk
  # OR use a privileged ephemeral pod to dd if=/dev/zero of=/dev/sdb bs=1M count=100
  echo "Need to zero /dev/sdb on $ip"
done

# 4. Delete OSD deployments + prepare jobs
kubectl $KCONFIG -n rook-ceph delete deploy -l app=rook-ceph-osd
kubectl $KCONFIG -n rook-ceph delete jobs -l app=rook-ceph-osd-prepare

# 5. Operator will re-prepare with fresh state
sleep 60
kubectl $KCONFIG -n rook-ceph get pods -l app=rook-ceph-osd-prepare -w
# Wait for prepare jobs Complete; then OSD deployments appear
```

### Verification

```bash
# 1. ceph status from operator
kubectl $KCONFIG -n rook-ceph exec deploy/rook-ceph-operator -- ceph -s | head -20
# Want: 3 mons in quorum, 7 osds up

# 2. CephCluster healthy
kubectl $KCONFIG -n rook-ceph get cephcluster
# Want: PHASE=Ready, HEALTH=HEALTH_OK

# 3. PVC smoke test
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
sleep 20
kubectl $KCONFIG -n default get pvc ceph-smoke-test
# Want: STATUS=Bound
kubectl $KCONFIG -n default delete pvc ceph-smoke-test
```

### Prevention

- **Never restart the operator** while the mon-endpoints CM is being modified — see [[rook-operator-restart-state-loss]]
- **Don't delete OSD deployments** during incomplete cluster bootstrap — let operator finish first
- **Use the rook upstream "purge-osd" job** for OSD removal — `kubectl create -f deploy/examples/osd-purge.yaml` from the rook repo
- **PromRule `CephOSDDown`** — alert if any OSD reports down for > 5 min
- **Phase 4 backup**: regular `ceph auth export` to S3 so keys are recoverable independently

### Related

- [[rook-mon-crashloop]] — sister symptom in the mon layer
- [[rook-operator-restart-state-loss]] — the mistake that creates this
- [[stuck-finalizer-removal]] — general finalizer-removal pattern
- Memory: `[ROOK-CEPH-IMPLEMENTATION-2026-06-19]` — full architecture

### Memory pointers

- `[ROOK-CEPH-IMPLEMENTATION-2026-06-19]` — Rook architecture + phases
- Upstream Rook disaster recovery: https://rook.io/docs/rook/latest-release/Troubleshooting/disaster-recovery/
- Upstream osd-purge job: https://rook.io/docs/rook/latest-release/Storage-Configuration/Advanced/ceph-osd-mgmt/

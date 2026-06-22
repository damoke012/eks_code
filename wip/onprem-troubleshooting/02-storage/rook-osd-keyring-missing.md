# Rook-Ceph OSDs CrashLoop — Bluestore key vs mon auth key mismatch

**Status:** PROVEN 2026-06-22 — Option A.1 (mon-side `ceph auth import` to match bluestore) followed by Option B (per-OSD purge + wipe + re-prepare for OSDs that still crash on PG peering) recovered op-usxpress-dev's 7 OSDs after 3 days down.

**Symptom:**
- `kubectl -n rook-ceph get pods -l app=rook-ceph-osd` shows OSDs in `CrashLoopBackOff` (1/2 containers Running, the `osd` container failing)
- OSD daemon logs show:
  ```
  monclient(hunting): handle_auth_bad_method server allowed_methods [2] but i only support [2]
  failed to fetch mon config (--no-mon-config to skip)
  ```
- The `[2] but i only support [2]` error is misleading — both sides speak cephx; the actual cause is the OSD's keyring doesn't match what mon has registered
- `ceph -s` (from toolbox or operator) shows `osd: 0 osds: 0 up, 0 in` or similar — OSDs never join

**Root cause:**
The cephx authentication for an OSD is split across THREE sources of truth:

1. **Mon auth database** — `ceph auth get osd.X` returns the key mons will accept
2. **Bluestore label on /dev/sdb** — `ceph-bluestore-tool show-label --dev /dev/sdb` returns the key the OSD presents, embedded in the disk's metadata at OSD prepare time
3. **k8s Secret `rook-ceph-osd-X-keyring`** — historically primary; in modern Rook (v1.15+ raw mode) it's mostly ornamental because the keyring file at `/var/lib/ceph/osd/ceph-X/keyring` is primed by `ceph-volume raw activate` from the **bluestore label**, NOT the Secret

If sources 1 and 2 disagree, the OSD presents a key the mon won't accept → `handle_auth_bad_method`. This happens when:
- A partial bootstrap left mon auth at one epoch and disk bluestore at another
- mons were re-created (e.g., disaster recovery) without re-extracting OSD keys
- A bootstrap-from-scratch attempt re-generated OSD auth entries while bluestore labels stayed at the original epoch

**IaC coverage:** ⚠
- CephCluster CR + Rook operator are correct; failure mode arises from bootstrap disruption
- Recovery is operational (not a single IaC change)
- IaC PREVENTION: ensure the bootstrap sequence (mons → operator → osd-prepare) completes atomically; do NOT restart the operator during mon-endpoints CM disruption (see [[rook-operator-restart-state-loss]])

**IaC location:**
- `iaac-talos-flux-platform/infrastructure/rook-ceph-cluster/cephcluster.yaml` — CR is fine
- `iaac-talos-flux-platform/infrastructure/rook-ceph-operator/` — operator deployment

### Resolution — PROVEN sequence (Option A.1 → Option B as needed)

#### Pre-requisites

1. **Mons must be in quorum.** Verify:
   ```bash
   KCONFIG="--server=https://10.10.82.50:6443 --insecure-skip-tls-verify=true"
   kubectl $KCONFIG -n rook-ceph get pods -l app=rook-ceph-mon
   ```
   All 3 should be `2/2 Running`. If not, fix mons first via [[rook-mon-crashloop]].

2. **Deploy the rook-ceph-tools toolbox** if not present (the operator pod does NOT have ceph CLI usable for ad-hoc; you need the toolbox):
   ```bash
   cat <<EOF | kubectl apply -f -
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: rook-ceph-tools
     namespace: rook-ceph
     labels:
       app: rook-ceph-tools
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: rook-ceph-tools
     template:
       metadata:
         labels:
           app: rook-ceph-tools
       spec:
         dnsPolicy: ClusterFirstWithHostNet
         containers:
         - name: rook-ceph-tools
           image: quay.io/ceph/ceph:v18.2.4
           command:
           - /bin/bash
           - -c
           - |
             cat <<CONF > /etc/ceph/ceph.conf
             [global]
             mon_host = \$ROOK_CEPH_MON_HOST
             [client.admin]
             keyring = /etc/ceph/keyring
             CONF
             cat <<KEY > /etc/ceph/keyring
             [client.admin]
             key = \$ROOK_CEPH_SECRET
             KEY
             chmod 600 /etc/ceph/keyring
             while true; do sleep 30; done
           env:
           - name: ROOK_CEPH_MON_HOST
             valueFrom:
               secretKeyRef:
                 name: rook-ceph-config
                 key: mon_host
           - name: ROOK_CEPH_SECRET
             valueFrom:
               secretKeyRef:
                 name: rook-ceph-mon
                 key: ceph-secret
           volumeMounts:
           - mountPath: /etc/ceph
             name: ceph-config
         volumes:
         - name: ceph-config
           emptyDir: {}
   EOF
   ```

#### Option A.1 — Align mon auth keys to bluestore labels (NON-DESTRUCTIVE)

**Why this works:** In Rook raw mode, `ceph-volume raw activate` writes `/var/lib/ceph/osd/ceph-X/keyring` from the bluestore label. The OSD daemon will present THAT key to mon. If we make mon's recorded key match the bluestore key, auth succeeds.

```bash
TOOLBOX=$(kubectl -n rook-ceph get pod -l app=rook-ceph-tools -o jsonpath='{.items[0].metadata.name}')

# Step 1: Get the osd → node mapping (which /dev/sdb is each OSD's)
kubectl -n rook-ceph get pods -l app=rook-ceph-osd \
  -o custom-columns='OSD:.metadata.labels.osd,POD:.metadata.name,NODE:.spec.nodeName'

# Step 2: For each OSD, read the bluestore osd_key from /dev/sdb via a privileged
# pod on that node. Build a `ceph auth import` file.
> /tmp/osd-bluestore-keys.txt
declare -A OSD_NODE=(
  [0]=<node-for-osd0>
  [1]=<node-for-osd1>
  # ... fill in all
)

for i in 0 1 2 3 4 5 6; do
  NODE=${OSD_NODE[$i]}
  POD="inspect-osd${i}-sdb"

  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  namespace: rook-ceph
spec:
  nodeName: $NODE
  restartPolicy: Never
  tolerations:
  - operator: Exists
  containers:
  - name: i
    image: quay.io/ceph/ceph:v18.2.4
    command: ["sleep","120"]
    securityContext:
      privileged: true
    volumeMounts:
    - { name: dev, mountPath: /dev }
  volumes:
  - { name: dev, hostPath: { path: /dev } }
EOF

  kubectl -n rook-ceph wait pod/$POD --for=condition=Ready --timeout=45s >/dev/null 2>&1

  LABEL=$(kubectl -n rook-ceph exec $POD -- ceph-bluestore-tool show-label --dev /dev/sdb 2>/dev/null)
  KEY=$(echo "$LABEL" | python3 -c "import json,sys; d=json.load(sys.stdin); print(list(d.values())[0]['osd_key'])")
  WHOAMI=$(echo "$LABEL" | python3 -c "import json,sys; d=json.load(sys.stdin); print(list(d.values())[0]['whoami'])")

  # CRITICAL: verify whoami matches the OSD ID we expected
  if [ "$i" != "$WHOAMI" ]; then
    echo "✗ MISMATCH: deployment osd.$i but bluestore says whoami=$WHOAMI on $NODE"
    echo "  Investigate before proceeding — wrong key on wrong OSD will fail auth"
    exit 1
  fi

  cat >> /tmp/osd-bluestore-keys.txt <<EOF
[osd.$i]
	key = $KEY
	caps mgr = "allow profile osd"
	caps mon = "allow profile osd"
	caps osd = "allow *"

EOF
  kubectl -n rook-ceph delete pod $POD --wait=false >/dev/null 2>&1
done

# Step 3: Copy the import file into toolbox + apply
kubectl cp /tmp/osd-bluestore-keys.txt rook-ceph/$TOOLBOX:/tmp/osd-keys.txt
kubectl exec -n rook-ceph $TOOLBOX -- ceph auth import -i /tmp/osd-keys.txt

# Step 4: Verify mon now has bluestore keys
for i in 0 1 2 3 4 5 6; do
  kubectl exec -n rook-ceph $TOOLBOX -- ceph auth get-key osd.$i; echo " ← osd.$i"
done
# Compare against /tmp/osd-bluestore-keys.txt — should match line-for-line

# Step 5: Restart OSD pods
kubectl -n rook-ceph delete pods -l app=rook-ceph-osd

# Step 6: Watch — expected: all 7 OSDs go 2/2 Running
sleep 60
kubectl -n rook-ceph get pods -l app=rook-ceph-osd
kubectl exec -n rook-ceph $TOOLBOX -- ceph -s | head -15
```

**Expected outcome (Option A.1):** Auth issue resolved. OSDs authenticate successfully.

**Common follow-on issue:** Some OSDs may STILL CrashLoopBackOff after auth is fixed — but now with a DIFFERENT error: PG peering assertion `same_interval_since=0`. See [[rook-osd-pg-peering-crash]]. Proceed to Option B for those.

#### Option B — Per-OSD purge + wipe + re-prepare (NUCLEAR, but SAFE on zero-data clusters)

Use when:
- Option A.1 doesn't fix some/all OSDs (typically due to stale PG state — see [[rook-osd-pg-peering-crash]])
- OR the cluster has no live data (e.g., during bringup, before any application data was written)

For each failing OSD:

```bash
OSDID=<N>
NODE=<worker-hosting-osd.N>
TOOLBOX=$(kubectl -n rook-ceph get pod -l app=rook-ceph-tools -o jsonpath='{.items[0].metadata.name}')

# 1. Stop the OSD deployment (prevents pod from coming back during purge)
kubectl -n rook-ceph scale deploy rook-ceph-osd-$OSDID --replicas=0

# 2. Mark out + purge from cluster
kubectl exec -n rook-ceph $TOOLBOX -- ceph osd out osd.$OSDID
kubectl exec -n rook-ceph $TOOLBOX -- ceph osd purge $OSDID --yes-i-really-mean-it

# 3. Delete Rook deployment + prepare job
kubectl -n rook-ceph delete deploy rook-ceph-osd-$OSDID
PREP=$(kubectl -n rook-ceph get jobs -o name | grep "rook-ceph-osd-prepare-$NODE" | head -1)
[ -n "$PREP" ] && kubectl -n rook-ceph delete $PREP

# 4. Wipe /dev/sdb on the node via privileged pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: wipe-osd-$OSDID
  namespace: rook-ceph
spec:
  nodeName: $NODE
  restartPolicy: Never
  tolerations:
  - operator: Exists
  containers:
  - name: wipe
    image: alpine:3.19
    command:
    - sh
    - -c
    - |
      dd if=/dev/zero of=/dev/sdb bs=1M count=100
      blockdev --rereadpt /dev/sdb 2>&1 || true
      echo "wipe complete: \$(dd if=/dev/sdb bs=1024 count=1 2>/dev/null | xxd | head -1)"
    securityContext: { privileged: true }
    volumeMounts:
    - { name: dev, mountPath: /dev }
  volumes:
  - { name: dev, hostPath: { path: /dev } }
EOF

sleep 15
kubectl -n rook-ceph logs wipe-osd-$OSDID
kubectl -n rook-ceph delete pod wipe-osd-$OSDID --wait=false
```

After ALL the failing OSDs are purged + wiped, trigger operator re-discovery (single reconcile re-prepares all wiped nodes in parallel):

```bash
kubectl -n rook-ceph delete pod -l app=rook-ceph-operator
sleep 10
flux reconcile kustomization rook-ceph-cluster -n flux-system

# Wait ~3 min for prepare jobs + new OSD deployments
sleep 180
kubectl -n rook-ceph get pods -l app=rook-ceph-osd
kubectl exec -n rook-ceph $TOOLBOX -- ceph -s
```

### Verification — PROVEN endpoints (2026-06-22 recovery)

```bash
TOOLBOX=$(kubectl -n rook-ceph get pod -l app=rook-ceph-tools -o jsonpath='{.items[0].metadata.name}')

# 1. All OSDs up + in
kubectl exec -n rook-ceph $TOOLBOX -- ceph -s | head -15
# Want: 7 osds: 7 up, 7 in

# 2. CephCluster healthy
kubectl -n rook-ceph get cephcluster
# Want: PHASE=Ready, HEALTH=HEALTH_OK (or WARN for unrelated reasons)

# 3. PGs active+clean
kubectl exec -n rook-ceph $TOOLBOX -- ceph -s | grep pgs
# Want: NNN active+clean (0 inactive/unknown/incomplete)

# 4. PVC smoke test against ceph-block storage class
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: ceph-smoke-test, namespace: default }
spec:
  storageClassName: ceph-block
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
EOF
sleep 20
kubectl -n default get pvc ceph-smoke-test
# Want: STATUS=Bound
kubectl -n default delete pvc ceph-smoke-test
```

### Prevention

1. **Don't restart the operator during cluster state transitions** — see [[rook-operator-restart-state-loss]]
2. **Don't clear mon-endpoints CM finalizer manually** — investigate the underlying lifecycle issue first
3. **PromRule `RookCephOSDDown`** — alert on OSDs CrashLoopBackOff > 5 min so this surfaces fast
4. **Phase 4 backup** — regular `ceph auth export` to S3 + periodic snapshot of bluestore labels so keys can be cross-checked

### Related

- [[rook-osd-pg-peering-crash]] — follow-on PG peering assertion crash that requires Option B
- [[rook-operator-restart-state-loss]] — the mistake that initially created this situation
- [[rook-mon-crashloop]] — mon issues that block recovery
- [[stuck-finalizer-removal]] — general pattern for stuck finalizers

### Memory pointers

- `[ROOK-CEPH-IMPLEMENTATION-2026-06-19]` — full Rook architecture
- Session log: 2026-06-22 — proven full recovery sequence end-to-end on op-usxpress-dev
- Upstream Rook DR docs: https://rook.io/docs/rook/latest-release/Troubleshooting/disaster-recovery/
- Upstream osd-purge job: https://rook.io/docs/rook/latest-release/Storage-Configuration/Advanced/ceph-osd-mgmt/

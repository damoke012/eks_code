# Rook-Ceph OSD CrashLoop on PG peering — `same_interval_since=0` assertion

**Status:** PROVEN 2026-06-22. Hit during op-usxpress-dev recovery AFTER fixing the bluestore-vs-mon key mismatch. 6 of 7 OSDs continued to crashloop with a different (peering, not auth) error. Fixed by per-OSD purge + wipe + re-prepare since cluster had 0 objects.

**Symptom:**
- OSD auth is healthy (`ceph auth get osd.X` returns the right key — see [[rook-osd-keyring-missing]] for that pre-condition)
- OSD daemon container starts, init containers succeed (chown, activate, expand-bluefs)
- OSD container then crashes within ~5 seconds with a Ceph internal assertion in the `osd` container log:
  ```
  *** Caught signal (Aborted) **
   in thread 7f97a37cb640 thread_name:tp_osd_tp
   ...
   4: (PeeringState::Reset::react(PeeringState::AdvMap const&)+0x28c)
   ...
  PeeringState.cc:620: FAILED ceph_assert(info.history.same_interval_since != 0)
  ```
- `ceph -s` shows the OSDs **briefly** appear as `up, in` before they crash again, oscillating
- `ceph osd tree` shows them under their correct host buckets but `down` status
- `ceph health detail` reports `91 pgs inactive, 1 pg incomplete, 53 pgs undersized`
- Subset of OSDs may succeed (their PGs happen to have non-zero `same_interval_since`); others fail consistently

**Root cause:**
The Ceph PG peering state machine asserts that any PG re-entering the `Reset` state has a non-zero `same_interval_since` (sis) — the epoch at which the current interval started. If an OSD's local PG metadata has `sis=0` (because the PG never recorded an interval during the original failed bootstrap, OR the local state desynced from cluster state during a long downtime), the assertion fires on the FIRST map advance after the OSD comes up.

How this happens:
- Cluster was running briefly, PGs were created
- Cluster got disrupted (mon crashes, OSDs down for many epochs)
- OSD's local PG state is stale; assumes it was recently reset but cluster moved on
- When OSD reconnects, the cluster pushes a fresh OSDMap
- PG enters Reset state to re-peer
- `Reset::react(AdvMap)` runs `start_peering_interval(...)` which asserts `sis != 0` — and the assertion fails because the local PG's history was never properly initialized

For on-prem cluster, this typically surfaces when:
- OSDs were down for many days
- Cluster map advanced significantly during that time
- A different code path (not auth, not bluestore mkfs) re-introduced PG state to memory at boot

**IaC coverage:** ⚠
- Not preventable via IaC for an existing cluster in this state
- Prevention for QA/PROD: minimize OSD downtime + monitor osd-state alerts so this doesn't compound

**IaC location:**
- N/A — operational recovery, not codifiable as a single IaC change
- The IaC artifact that IS valuable: a Recovery k8s Job manifest at `infrastructure/rook-recovery-jobs/osd-purge.yaml` (template), see "IaC artifact" section below

### Diagnosis — confirm this is the issue

```bash
# Grab a failing OSD pod
POD=$(kubectl -n rook-ceph get pods -l osd=N -o jsonpath='{.items[0].metadata.name}')

# Look at the osd container log (not init container, not log-collector)
kubectl -n rook-ceph logs $POD -c osd --tail=40 | grep -E 'PeeringState|same_interval|assert|caught signal'
# If you see "PeeringState.cc:620: FAILED ceph_assert(info.history.same_interval_since != 0)" — this entry
```

Compare to a WORKING OSD (e.g., osd.4 in the 2026-06-22 incident) — its log shows normal PG activation lines:
```
osd.X pg_epoch: NNNN pg[A.B( empty local-lis/les=0/0 n=0 ec=NNNN/NN ... sis=NNNN) [X] r=0 ...
                                                                              ^^^^^^^^^^
                                                                              non-zero sis
```

### Resolution — per-OSD purge + wipe + re-prepare

**ONLY safe if the cluster has no live data you care about**, i.e., `ceph -s` shows `objects: 0 objects, 0 B used` OR you've confirmed no app data is on the failing OSDs' PGs. For clusters WITH data, use `ceph-objectstore-tool` to surgically trim bad PG state (complex, beyond this entry's scope).

Apply Option B from [[rook-osd-keyring-missing]] to each failing OSD. The procedure:
1. Stop OSD deployment
2. `ceph osd out + purge`
3. Delete Rook deployment + prepare job
4. Wipe `/dev/sdb` on the node (privileged pod, `dd` first 100MB)
5. Restart operator + trigger Flux reconcile → operator runs fresh osd-prepare → new OSD with clean PG state

Critical: **DO NOT** wipe a known-good OSD's disk — even if it has stale state. The cluster needs at least one OSD with valid metadata to bootstrap PG history into the new OSDs. In the 2026-06-22 incident, osd.4 was working (had non-zero sis); we kept it as the anchor.

### IaC artifact — pre-built recovery Job for QA setup

For QA cluster bootstrap docs + future incidents, ship this Job template at `iaac-talos-flux-platform/infrastructure/rook-recovery-jobs/osd-wipe.yaml` (manual apply only, not in any Flux Kustomization):

```yaml
# WARNING — destructive. Wipes /dev/sdb on the specified node. Apply manually
# only after confirming the OSD on that node should be re-bootstrapped.
#
# Substitute <NODE> with the target worker hostname before apply.
apiVersion: v1
kind: Pod
metadata:
  name: osd-wipe-<NODE>
  namespace: rook-ceph
spec:
  nodeName: <NODE>
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
      set -e
      echo "Wipe start: /dev/sdb on $(hostname)"
      ls -la /dev/sdb
      SIZE=$(blockdev --getsize64 /dev/sdb)
      echo "Size: $SIZE bytes"
      dd if=/dev/zero of=/dev/sdb bs=1M count=100 status=progress
      blockdev --rereadpt /dev/sdb 2>&1 || true
      echo ""
      echo "Post-wipe first 1KB hex (should be all zeros):"
      dd if=/dev/sdb bs=1024 count=1 2>/dev/null | xxd | head -3
      echo "Wipe complete"
    securityContext:
      privileged: true
    volumeMounts:
    - name: dev
      mountPath: /dev
  volumes:
  - name: dev
    hostPath:
      path: /dev
```

### Verification

```bash
# After purge + wipe + re-prepare, watch for OSDs to come back
sleep 180
kubectl -n rook-ceph get pods -l app=rook-ceph-osd
# Want: all N OSDs in 2/2 Running state, no CrashLoopBackOff

TOOLBOX=$(kubectl -n rook-ceph get pod -l app=rook-ceph-tools -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n rook-ceph $TOOLBOX -- ceph -s | head -15
# Want: 7 osds: 7 up, 7 in, pgs: NNN active+clean

# Smoke test storage
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: ceph-smoke-test, namespace: default }
spec:
  storageClassName: ceph-block
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
EOF
sleep 15
kubectl -n default get pvc ceph-smoke-test    # Want: STATUS=Bound
kubectl -n default delete pvc ceph-smoke-test
```

### Prevention

1. **PromRule `RookCephOSDCrashLooping`** — alert if OSD pod has `restarts > 10 in 30 min` so this surfaces fast
2. **PromRule `RookCephClusterDegraded`** — alert on `osd_up < osd_in` or `pgs_inactive > 5`
3. **For long planned downtimes**: set `noout` on the cluster before stopping OSDs (prevents map epoch advancement that creates the sis=0 condition)
4. **Phase 4 backup** — periodic `ceph osd dump` + `ceph pg dump` snapshot so we can diff and detect drift

### Related

- [[rook-osd-keyring-missing]] — the prerequisite fix; this entry is the follow-on
- [[rook-operator-restart-state-loss]] — original incident root cause that led to this scenario
- Memory: `[ROOK-CEPH-IMPLEMENTATION-2026-06-19]`

### Memory pointers

- 2026-06-22 incident: 7 OSDs CrashLoopBackOff for 3 days. After auth import (Option A.1) fixed cephx, 6 OSDs still hit this assertion. Surgical purge+wipe of 6 (kept osd.4 as anchor) recovered the cluster in ~20 minutes. PVC smoke test passed.
- Upstream Ceph reference: https://docs.ceph.com/en/reef/dev/osd_internals/peering/
- Upstream Rook OSD management: https://rook.io/docs/rook/latest-release/Storage-Configuration/Advanced/ceph-osd-mgmt/

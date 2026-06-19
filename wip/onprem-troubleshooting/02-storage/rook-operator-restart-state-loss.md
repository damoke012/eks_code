# Rook Operator Restart Causes State Loss During Incomplete Bootstrap

**Symptom:**
- After restarting `rook-ceph-operator` (e.g., to "kick" reconciliation), the operator goes into a **bootstrap-from-scratch loop**:
  ```
  E | op-mon: failed to schedule mon "a". failed to schedule canary pod(s)
  E | op-mon: failed to schedule mon "b". failed to schedule canary pod(s)
  E | op-mon: failed to schedule mon "c". failed to schedule canary pod(s)
  ```
- Operator creates `rook-ceph-mon-X-canary` deployments (a/b/c)
- Canaries stuck `Pending` with `volume node affinity conflict` events
- Operator can't reach existing mons (they're still 2/2 Running but appear "invisible")
- `kubectl -n rook-ceph get cm rook-ceph-mon-endpoints -o yaml` shows EMPTY data:
  ```yaml
  data:
    csi-cluster-config-json: '[{"clusterID":"rook-ceph","monitors":[],...}]'
    data: ""
    mapping: '{"node":{}}'
    maxMonId: "-1"
    outOfQuorum: ""
  ```
- CephCluster CR: `PHASE=Ready` BUT operator log says `failed to configure ceph cluster`

**Root cause:**
The operator's bootstrap discovery relies on the `rook-ceph-mon-endpoints` ConfigMap to know:
- How many mons exist
- Their addresses  
- Their identity mapping

If this CM has empty `data`, the operator thinks the cluster is uninitialized. It tries to bootstrap fresh:
1. Creates canary mon deployments to test which nodes can host new mons
2. Canary deployments use anti-affinity vs existing mon PVCs → they fail to schedule (correctly!)
3. Operator gives up: "failed to schedule mons"

Meanwhile, the EXISTING mon deployments (a/b/c) are still Running on their original nodes with healthy mon DBs in `/var/lib/rook` → but operator doesn't notice because the CM doesn't reference them.

How does the CM end up empty?

1. The OLD CM was stuck with `deletionTimestamp` + `ceph.rook.io/disaster-protection` finalizer from a prior recovery
2. Someone (yesterday's me) cleared the finalizer to "clean up"
3. The CM deleted (because deletionTimestamp was in the past)
4. Operator AUTO-RECREATED a fresh CM — with EMPTY data, because it hadn't reconnected to mons yet
5. Operator restart triggered a full reconcile from the empty CM → bootstrap-from-scratch attempt

**IaC coverage:** ❌ (procedural mistake; not codifiable as IaC)

**IaC location:** N/A — this is operational discipline

### Resolution via IaC

None. This is a "don't do this" rule.

### Manual resolution — if you've already caused it

**Step 1 — Confirm existing mons are still Running:**

```bash
KCONFIG="--server=https://10.10.82.179:6443 --insecure-skip-tls-verify=true"

kubectl $KCONFIG -n rook-ceph get pods -l app=rook-ceph-mon -o wide
# Want: 3 mon pods Running (a/b/c, NOT canaries)
```

**Step 2 — Force the EXISTING mons to re-register via scale-down/up:**

```bash
# Scale to 0 (preserves PVC + deployment spec)
for mon in a b c; do
  kubectl $KCONFIG -n rook-ceph scale deploy rook-ceph-mon-$mon --replicas=0
done

# Wait briefly
sleep 10

# Scale back to 1 — operator detects "missing" mons and re-binds via /var/lib/rook
for mon in a b c; do
  kubectl $KCONFIG -n rook-ceph scale deploy rook-ceph-mon-$mon --replicas=1
done

# Watch operator reconcile
sleep 60
kubectl $KCONFIG -n rook-ceph logs deploy/rook-ceph-operator --tail=30
```

**Step 3 — Verify mon-endpoints CM repopulates:**

```bash
kubectl $KCONFIG -n rook-ceph get cm rook-ceph-mon-endpoints -o jsonpath='{.data.data}'
echo ""
# Want: "a=<IP>:6789,b=<IP>:6789,c=<IP>:6789" (NOT empty)
```

**Step 4 — Wait for operator to clean up canary deployments:**

```bash
sleep 60
kubectl $KCONFIG -n rook-ceph get deploy | grep canary
# Want: empty
```

### Verification

```bash
# 1. CephCluster Ready
kubectl $KCONFIG -n rook-ceph get cephcluster
# Want: PHASE=Ready, HEALTH=HEALTH_OK (or WARN if OSDs separate issue)

# 2. ceph status from operator pod
kubectl $KCONFIG -n rook-ceph exec deploy/rook-ceph-operator -- ceph -s | head -20
# Want: mon quorum, osd up/in

# 3. Canary deployments gone
kubectl $KCONFIG -n rook-ceph get deploy | grep -v canary
```

### Prevention

**Don't do this:**
1. **Don't clear the `rook-ceph-mon-endpoints` finalizer without operator awareness.** If the CM is stuck with `deletionTimestamp`, it's because Rook's deletion lifecycle is in progress (or hung). Solve the underlying lifecycle issue first.
2. **Don't restart `rook-ceph-operator` to "kick reconciliation"** during cluster state transitions. The operator's state machine assumes the CM is the source of truth — restart re-reads the CM, and if it's been wiped or is mid-recreation, you trigger a bootstrap-from-scratch.
3. **Don't delete mon endpoint ConfigMap directly.** Even if it looks "wrong", the operator created it for a reason. Investigate why before destroying.

**Do this instead:**

- **For "stuck" mon-endpoints CM with `deletionTimestamp`**: 
  - Check operator logs — what was it trying to do when the CM got marked for deletion?
  - If it's truly stuck (operator gave up), prefer `kubectl annotate` to add an exemption rather than clear the finalizer outright
  - If you MUST clear the finalizer, do it WITHOUT restarting the operator afterward
  
- **To kick reconciliation cleanly**:
  - `kubectl -n flux-system annotate kustomization rook-ceph-cluster reconcile.fluxcd.io/requestedAt="$(date -u +%s)" --overwrite`
  - Let Flux handle reconciliation rather than poking the operator directly

- **Before any destructive operation on Rook**:
  - Snapshot mon DBs from local-path PVCs to S3 (Phase 4 plan)
  - Snapshot `rook-ceph-mon-endpoints` CM to a backup
  - Have the Rook disaster recovery URL open: https://rook.io/docs/rook/latest-release/Troubleshooting/disaster-recovery/

### Related

- [[stuck-finalizer-removal]] — the well-meaning fix that caused this incident
- [[rook-mon-crashloop]] — sister symptom in the mon layer
- [[rook-osd-keyring-missing]] — downstream consequence (OSD secrets never created)
- Memory: `[Issue codify + push immediately]`, `[Confirm before executing]`, `[ROOK-CEPH-IMPLEMENTATION-2026-06-19]`

### Memory pointers

- 2026-06-19 PM session — I (Claude) caused this by suggesting both finalizer cleanup + operator restart in close succession. Mons were healthy; the cleanup was unnecessary; the restart cascaded.
- Upstream Rook DR docs: https://rook.io/docs/rook/latest-release/Troubleshooting/disaster-recovery/
- Upstream "I see CrashLoopBackOff": https://rook.io/docs/rook/latest-release/Troubleshooting/ceph-common-issues/

# Rook-Ceph Mon Crash-Loop (OSDs Blocked)

**Symptom:**
- `rook-ceph-mon-a` / `-b` / `-c` in `CrashLoopBackOff`, restart count grows linearly
- `kubectl -n rook-ceph get cephcluster` shows `PHASE=Progressing`, `HEALTH=HEALTH_WARN` or `HEALTH_ERR`
- OSDs never spawn — `kubectl -n rook-ceph get pods -l app=rook-ceph-osd` is empty
- `ceph status` commands timeout with `failed to get status. . timed out: exit status 1`
- Operator pod (`rook-ceph-operator-*`) may be Pending (memory pressure)
- Possibly: `rook-ceph-mon-endpoints` ConfigMap stuck with `deletionTimestamp` + finalizer `ceph.rook.io/disaster-protection`

**Root cause:**
Multiple possible causes for mon crash:
1. **Volume corruption** — local-path PVC backing the mon contains corrupt mon DB
2. **Mon DB schema mismatch** — operator upgraded but mon DB on disk wasn't migrated
3. **Network partition** — mons can't form quorum because peer-to-peer routing broken (e.g., during CN drift)
4. **Resource starvation** — mon OOMKilled before achieving sync
5. **Stuck finalizer** — operator can't recreate fresh mon endpoints because old ConfigMap won't delete

**IaC coverage:** ⚠ (CephCluster CR codified; recovery procedure NOT yet codified)

**IaC location:**
- `iaac-talos-flux-platform/infrastructure/rook-ceph-cluster/cephcluster.yaml` — CR with `deviceFilter: ^sdb$` (PR #44 — merged)
- `iaac-talos-flux-platform/infrastructure/rook-ceph-operator/` — Operator HelmRelease

### Resolution via IaC

For fresh clusters: the CR is applied by Flux, operator creates mons + OSDs from scratch. No corruption to recover from. Expected healthy within 5-10 min.

For DR after corruption: no IaC yet — see [`ROOK-CEPH-IMPLEMENTATION-2026-06-19.md`](../../iac-sweep-jun18/ROOK-CEPH-IMPLEMENTATION-2026-06-19.md) § "Phase 4" for the planned snapshot-to-S3 recovery path.

### Manual resolution

**Step 1 — Diagnose which mon is failing:**

```bash
KCONFIG="--server=https://10.10.82.179:6443 --insecure-skip-tls-verify=true"

# Show mon pod state + restart counts
kubectl $KCONFIG -n rook-ceph get pods -l app=rook-ceph-mon -o wide

# Pull logs from each crash-looping mon
for mon in a b c; do
  echo "=== mon-$mon ==="
  kubectl $KCONFIG -n rook-ceph logs rook-ceph-mon-$mon-* --tail=50 2>&1 | head -60
  echo ""
done

# Check operator state — might be Pending
kubectl $KCONFIG -n rook-ceph get pods -l app=rook-ceph-operator
kubectl $KCONFIG -n rook-ceph describe pod -l app=rook-ceph-operator | tail -20
```

**Step 2 — Force-remove stuck mon-endpoints finalizer (if present):**

```bash
# Check ConfigMap state
kubectl $KCONFIG -n rook-ceph get configmap rook-ceph-mon-endpoints \
  -o jsonpath='{.metadata.deletionTimestamp}' && echo ""

# If deletionTimestamp set → force-remove finalizer
kubectl $KCONFIG -n rook-ceph patch configmap rook-ceph-mon-endpoints \
  -p '{"metadata":{"finalizers":null}}' --type=merge

# ConfigMap deletes immediately; operator recreates it fresh on next reconcile
```

**Step 3 — If mons have corrupt PVC data, scrub + recreate:**

```bash
# Identify the mon's PVC
kubectl $KCONFIG -n rook-ceph get pvc -l app=rook-ceph-mon

# Save the CR YAML before destructive changes
kubectl $KCONFIG -n rook-ceph get cephcluster rook-ceph -o yaml > /tmp/cephcluster-pre.yaml

# DESTRUCTIVE — delete mon PVC + pod, lets operator recreate clean
# Only do this if mon DB corruption is confirmed (logs show "checksum mismatch" or similar)
MON_LETTER=a   # change for each mon to redo
kubectl $KCONFIG -n rook-ceph delete pvc rook-ceph-mon-$MON_LETTER --grace-period=0 --force
kubectl $KCONFIG -n rook-ceph delete pod rook-ceph-mon-$MON_LETTER-* --grace-period=0 --force

# Wait for operator to recreate
sleep 30
kubectl $KCONFIG -n rook-ceph get pods -l app=rook-ceph-mon
```

**Step 4 — Kick the operator if it's stuck Pending or stale:**

```bash
# Force operator restart to pick up clean state
kubectl $KCONFIG -n rook-ceph rollout restart deploy rook-ceph-operator

# Watch operator reconcile cycle
kubectl $KCONFIG -n rook-ceph logs deploy/rook-ceph-operator --tail=50 -f
# Ctrl-C after seeing "successfully started"
```

**Step 5 — Watch OSDs spawn once mons are healthy:**

```bash
# OSDs appear within ~5 min after quorum
kubectl $KCONFIG -n rook-ceph get pods -l app=rook-ceph-osd-prepare -w
# Ctrl-C after all 7 complete

kubectl $KCONFIG -n rook-ceph get pods -l app=rook-ceph-osd -o wide
# Expect: 7 OSDs Running, one per worker
```

### Verification

```bash
# 1. CephCluster phase + health
kubectl $KCONFIG -n rook-ceph get cephcluster
# Want: PHASE=Ready, HEALTH=HEALTH_OK

# 2. Mon quorum
kubectl $KCONFIG -n rook-ceph exec deploy/rook-ceph-operator -- \
  ceph -s 2>&1 | head -20
# Expect: 3 mons in_quorum

# 3. OSDs all up
kubectl $KCONFIG -n rook-ceph get pods -l app=rook-ceph-osd -o wide
# Expect: 7 pods Running

# 4. StorageClasses produced
kubectl $KCONFIG get sc
# Expect: ceph-block, ceph-fs, ceph-bucket alongside local-path
```

### Prevention

- **Mon PVC backups** (Phase 4 — drafted): snapshot mon PVCs to S3 every 6h
- **PromRule `CephMonDown`** (Track 2 — drafted): fires when < 2 of 3 mons healthy
- **Operator-replacement playbook**: documented in implementation doc
- **Worker memory bumped to 12 GB** (PR #40 merged): reduces operator scheduling failures
- **No CP scheduling** (CephCluster CR `placement.all` excludes CPs)

### Related

- [[stuck-finalizer-removal]] — common companion issue
- [[../05-terraform-octopus/octopus-tfapply-variable]] — Phase 2 CR depends on Flux reconcile
- [[../../../iac-sweep-jun18/ROOK-CEPH-IMPLEMENTATION-2026-06-19]] — full Rook arch + phases

### Memory pointers

- `[Session state Jun 19]` — mons crash-looping 10h+ at session end; Phase 2 CR live but blocked
- `[Vibin decisions March 31]` — Rook-Ceph after AHV decision
- Upstream Rook mon recovery: https://rook.io/docs/rook/latest-release/Storage-Configuration/Advanced/ceph-mon-health/

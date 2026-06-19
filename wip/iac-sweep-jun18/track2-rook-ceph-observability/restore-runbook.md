# Rook-Ceph Restore Runbook (op-usxpress-dev + future QA/PROD)

**Target path on merge:** `docs/runbooks/rook-ceph-restore.md`

## Scope

This runbook covers Rook-Ceph recovery scenarios on the on-prem Talos cluster. It assumes the safe-placement values from PR #37 (op-dev) are in place — CSI plugins on workers only, mon/mgr/osd resources sized for 4 GB workers.

## Scenarios + responses

### Scenario A — CephCluster CR is healthy, OSD pod restarted

**Symptom:** `kubectl -n rook-ceph get cephcluster` shows `HEALTH_WARN`, an OSD pod is restarting.

**Action:**
1. Identify the OSD: `kubectl -n rook-ceph get pods -l app=rook-ceph-osd -o wide`
2. Check the worker's memory: `talosctl --nodes <IP> --endpoints <IP> memory`
3. If worker is < 200 MB free, that's the cause — OOM killed the OSD. Reschedule OSD by deleting the pod (operator will recreate) and consider:
   - Reducing OSD memory limit further in cephcluster.yaml
   - OR bumping worker RAM (Track 3 has the TF change)
4. If memory is fine, look at OSD logs for storage errors:
   ```bash
   kubectl -n rook-ceph logs rook-ceph-osd-N-xxxxx
   ```

**Recovery time:** ~5 min for OSD restart, ~30 min for rebalance.

### Scenario B — CephCluster CR exists but mons can't bootstrap

**Symptom:** PVCs stuck in `Pending`, `kubectl -n rook-ceph get cephcluster` shows `PROGRESSING` with `Detecting Ceph version` for > 10 min.

**Common causes:**
1. CSI plugin DaemonSets failed to schedule (placement values not honored) — STOP, this is the 2026-06-17 incident pattern, suspend Flux Kustomization immediately
2. Image pull blocked (corp egress blocking quay.io)
3. PSA labels missing on rook-ceph namespace

**Action:**
```bash
# Check CSI placement — DESIRED must equal worker count (7), NOT total nodes (10)
kubectl -n rook-ceph get ds csi-rbdplugin csi-cephfsplugin

# If DESIRED is wrong, IMMEDIATELY:
flux suspend kustomization rook-ceph-cluster -n flux-system
flux suspend kustomization rook-ceph-operator -n flux-system
kubectl -n rook-ceph delete ds csi-rbdplugin csi-cephfsplugin
# Then fix placement values, re-PR, re-merge

# Check image pull on detect-version pod
kubectl -n rook-ceph describe pod -l app=rook-ceph-detect-version

# Check PSA labels
kubectl get ns rook-ceph --show-labels
# Must include pod-security.kubernetes.io/enforce=privileged (Rook needs it)
```

### Scenario C — CephCluster CR is deleted (accidental)

**Symptom:** `kubectl -n rook-ceph get cephcluster` returns no resources, but operator + CSI are still running.

**This is recoverable if PVs still exist and the underlying disks weren't wiped.**

**Action:**
1. **STOP** — do not let Flux reconcile yet, that would create a fresh cluster with new mon keyring → existing data inaccessible
2. Identify the rook-ceph-cluster Flux Kustomization and suspend it:
   ```bash
   flux suspend kustomization rook-ceph-cluster -n flux-system
   ```
3. Restore the CephCluster CR from the backup of `mon-endpoints` ConfigMap + Secret:
   ```bash
   kubectl -n rook-ceph get cm,secret | grep mon
   # The keyring is in the rook-ceph-mon Secret — KEEP THIS, never delete
   ```
4. Re-apply the CephCluster CR from git (the safe-placement one in iaac-talos-flux-platform/infrastructure/rook-ceph-cluster/):
   ```bash
   kubectl apply -f cephcluster.yaml
   ```
5. Resume Flux:
   ```bash
   flux resume kustomization rook-ceph-cluster -n flux-system
   ```

### Scenario D — All OSDs gone, but PVCs and disks intact

**Symptom:** OSDs deleted (operator pod deleted with finalizers cleared, or namespace force-deleted). Underlying PVs still have data on `local-path` provisioner backing disks.

**Action:**
1. **STOP all writes** by suspending workloads using Ceph storage classes
2. Re-create the CephCluster CR (Scenario C) — keep the same `storageClassDeviceSets.name` so OSDs map back to existing disks
3. Operator's prepare-osd Job runs, **detects existing OSD on disk** (Ceph stores its UUID on disk), re-creates the OSD pod
4. Watch `ceph status` for recovery progress

**Recovery time:** depends on data volume; expect 5-30 min for re-attach.

### Scenario E — Full cluster restore (data loss, restoring from elsewhere)

**Not applicable on op-usxpress-dev yet** — Rook is freshly deployed, no real data has been written. Once user data lands on Ceph:
- File a separate ticket to implement off-cluster snapshot/backup (rbd export to S3, CephFS rsync to NAS)
- Document the restore flow there

## General principles

1. **Never delete CephCluster CR while CSI is still serving live PVCs.** Suspend Flux first, fix the underlying issue, then act.
2. **The `rook-ceph-mon` Secret is the only state that matters.** Lose it → cluster is unrecoverable. Add it to the cert-manager-backed secret backup loop (separate ticket).
3. **Placement values are sacred.** Any change to the safe-placement values from PR #37 must go through a re-roll PR using the same gates from `wip/infra-1532-rook-ceph-safe-reroll/DEPLOY-README.md`.
4. **CSI plugin DaemonSet DESIRED count = worker count (7).** If it's ever 10 (= total nodes), you're about to repeat the 2026-06-17 OOM cascade.

## Related
- 2026-06-17 incident: `docs/incidents/2026-06-17_cp-oom-cascade.md`
- Safe re-roll deploy plan: `wip/infra-1532-rook-ceph-safe-reroll/DEPLOY-README.md`
- `/onprem-safety` skill (Rules 1, 2, 4 directly applicable)

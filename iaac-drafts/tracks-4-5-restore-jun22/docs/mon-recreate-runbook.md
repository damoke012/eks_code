# INFRA-1536 — Mon PVC recreate runbook (operational)

## Goal

Expand existing mon PVCs from 10Gi → 20Gi. local-path-provisioner does NOT support online expansion, so we recreate mon-by-mon: delete the mon Deployment + PVC, let the Rook operator create new ones at the size now in `cephcluster.yaml` (20Gi as of PR #48).

## Pre-flight

```bash
export KUBECONFIG=~/.kube/op-usxpress-dev.yaml

# 1. Verify all 3 mons are in quorum + healthy
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s

# 2. Verify ceph health (must be HEALTH_OK or only WARN reasons unrelated to mons)
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph health detail

# 3. Tim's RW pre-baseline (per onprem-safety Rule 5)
kubectl -n risingwave get pods,svc,pvc > /tmp/rw-pre-mon-recreate.txt

# 4. Confirm IaC value is 20Gi (PR #48 merged)
cd ~/work/iaac-talos-flux-platform && git checkout op-dev && git pull
grep -A 5 "volumeClaimTemplate:" infrastructure/rook-ceph-cluster/cephcluster.yaml
```

## Recreate sequence (one mon at a time)

**CRITICAL**: only recreate ONE mon at a time. Wait for it to rejoin quorum before moving to the next.

### Phase 1: Recreate mon-a

```bash
export NS=rook-ceph
export MON=a

# A. Suspend operator so it doesn't fight us during the delete
kubectl -n $NS scale deploy rook-ceph-operator --replicas=0
sleep 5

# B. Delete the mon Deployment (operator will recreate when scaled up)
kubectl -n $NS delete deploy rook-ceph-mon-$MON --wait=true

# C. Delete the PVC (this is the destructive step — 10Gi PVC + PV gone)
kubectl -n $NS delete pvc rook-ceph-mon-$MON --wait=true

# D. Scale operator back up; it will recreate mon-$MON with 20Gi PVC
kubectl -n $NS scale deploy rook-ceph-operator --replicas=1

# E. Wait for the new mon to come up
sleep 30
kubectl -n $NS get pods -l app=rook-ceph-mon-$MON

# F. Verify new PVC is 20Gi
kubectl -n $NS get pvc rook-ceph-mon-$MON

# G. Verify mon rejoined quorum (this is the critical wait)
for i in {1..30}; do
  QUORUM=$(kubectl -n $NS exec deploy/rook-ceph-tools -- ceph mon stat 2>/dev/null | grep -o 'quorum [a-z,]*' | head -1)
  echo "Attempt $i: $QUORUM"
  if echo "$QUORUM" | grep -q "$MON"; then
    echo "mon-$MON rejoined quorum"
    break
  fi
  sleep 10
done

# H. Verify cluster health
kubectl -n $NS exec deploy/rook-ceph-tools -- ceph -s
```

**STOP and verify before proceeding to next mon.** All 3 mons must be in quorum.

### Phase 2: Recreate mon-b

Repeat above with `MON=b`. Wait for quorum.

### Phase 3: Recreate mon-c

Repeat above with `MON=c`. Wait for quorum.

## Post-flight

```bash
# All 3 mon PVCs should now be 20Gi
kubectl -n rook-ceph get pvc | grep mon

# Cluster fully healthy (only acceptable WARN: 1 daemons have recently crashed,
# which we can archive)
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph crash archive-all

# Tim's RW unchanged
kubectl -n risingwave get pods,svc,pvc > /tmp/rw-post-mon-recreate.txt
diff /tmp/rw-pre-mon-recreate.txt /tmp/rw-post-mon-recreate.txt
```

## Rollback

If a mon fails to rejoin quorum within 5 min:

1. Don't proceed to next mon
2. Check operator logs: `kubectl -n rook-ceph logs deploy/rook-ceph-operator --tail=50`
3. If the new mon can't be scheduled, check node memory + local-path-storage capacity
4. Worst case: restore mon from another mon's snapshot — see Rook docs "Disaster Recovery / Mon Restore"

## Why this works

- Ceph mon quorum tolerates 1 failure (with 3 mons, quorum needs 2)
- During mon-X recreate, mon-Y and mon-Z maintain quorum
- The recreated mon-X joins via `ceph mon join` (handled by Rook operator)
- mon data on disk is identical to other mons (replicated via Paxos)

## Skip option

If you'd rather defer: existing mon PVCs will auto-grow to 20Gi the next time a mon naturally rotates (e.g., node maintenance, mon pod restart picks up new template). The IaC value is bumped; this runbook just accelerates it.

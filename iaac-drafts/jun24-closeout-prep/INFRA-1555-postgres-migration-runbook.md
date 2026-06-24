# INFRA-1555 — Postgres rw-2 local-path → ceph-block migration runbook

| Field | Value |
|---|---|
| Ticket | INFRA-1555 |
| Cluster | op-usxpress-dev |
| Namespace | `risingwave-2` |
| Workload | Postgres metadata-store backing rw-2 RisingWave operator |
| Current storage | `local-path` PVC (node-bound, no replication) |
| Target storage | `ceph-block` (replicated, survives worker reschedule) |
| Estimated time | ~45 min including Velero pre-backup + post-verify |
| Blast radius | rw-2 namespace only (cloud-platform-owned validation instance, NOT Tim's `risingwave` namespace) |
| Coordination | Light Tim ping (rw-2 is ours, not his — but he should know rw-2 storage is changing as a courtesy) |

## Why this migration

The rw-2 Postgres meta-store is currently on `local-path`, meaning:
- The PVC is bound to a single worker; if that worker reschedules, Postgres pod stays Pending.
- No replication; a disk failure on that one worker is total data loss.
- Inconsistent with rw-2 Prometheus (already on ceph-block).

Moving to ceph-block matches the rest of rw-2 storage and matches our [observability ADR-001] storage decision. This is the last local-path PVC on a production workload in rw-2.

## Pre-flight (do NOT skip)

```bash
export KUBECONFIG=~/.kube/op-usxpress-dev.yaml

# 1. Verify rw-2 health BEFORE we touch anything
kubectl -n risingwave-2 get pods,svc,pvc > /tmp/rw2-pre-1555.txt
cat /tmp/rw2-pre-1555.txt

# 2. Identify the Postgres PVC name and size
kubectl -n risingwave-2 get pvc | grep -i postgres
# Expected: a PVC with storageClassName=local-path, size something like 8Gi or 10Gi

# 3. Identify the HelmRelease that owns Postgres (rw-2 chart vs separate postgres chart?)
kubectl -n risingwave-2 get helmreleases.helm.toolkit.fluxcd.io
# Look for "postgres" or "metaservices" or similar

# 4. Confirm Velero is healthy
kubectl -n velero get backups | head -5
velero version

# 5. RW-2 baseline: query Postgres directly to confirm metadata is healthy
POSTGRES_POD=$(kubectl -n risingwave-2 get pod -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}')
kubectl -n risingwave-2 exec -it "$POSTGRES_POD" -- psql -U postgres -c "\l" > /tmp/rw2-postgres-pre.txt
cat /tmp/rw2-postgres-pre.txt
```

**Stop here if:**
- Any rw-2 pod is not Running and Ready
- The Postgres PVC isn't on local-path (might already be migrated)
- Velero is unhealthy
- Postgres `\l` fails

## Step 1 — Light Tim ping (courtesy)

```
Hey Tim — going to migrate rw-2 Postgres meta-store from local-path to ceph-block in ~45 min.
This is rw-2 namespace (cloud-platform's), NOT your risingwave namespace. No impact on your prod RW.
Pinging as a heads-up since it's an rw-2 storage change. Will confirm rw-2 healthy post-migration.
```

Wait for ack (not approval — courtesy ping per [[feedback-protect-rw-onprem-workload]]).

## Step 2 — Velero pre-backup

```bash
TS=$(date -u +%Y%m%dT%H%M%SZ)
velero backup create rw2-postgres-pre-migration-$TS \
  --include-namespaces risingwave-2 \
  --wait

velero backup describe rw2-postgres-pre-migration-$TS --details
# Confirm Phase: Completed, no errors
```

## Step 3 — Suspend Flux so it doesn't fight the migration

```bash
# Identify the Kustomization that owns rw-2 (likely in iaac-talos-flux-platform's rw-2 dir)
flux get kustomizations -A | grep -i risingwave-2
# Suspend whichever owns the Postgres HR
flux suspend kustomization <name> -n flux-system

# Suspend the HelmRelease itself
flux suspend helmrelease <postgres-hr-name> -n risingwave-2
```

## Step 4 — Capture current PVC details

```bash
PVC_NAME=$(kubectl -n risingwave-2 get pvc | grep postgres | awk '{print $1}' | head -1)
echo "PVC to migrate: $PVC_NAME"
kubectl -n risingwave-2 get pvc "$PVC_NAME" -o yaml > /tmp/rw2-postgres-pvc-original.yaml

# Capture the size for the new PVC
PVC_SIZE=$(kubectl -n risingwave-2 get pvc "$PVC_NAME" -o jsonpath='{.spec.resources.requests.storage}')
echo "Current size: $PVC_SIZE"
```

## Step 5 — Scale Postgres deployment/statefulset to 0

```bash
# Determine the workload type
PG_WORKLOAD=$(kubectl -n risingwave-2 get sts,deploy -l app.kubernetes.io/name=postgresql -o name | head -1)
echo "Workload: $PG_WORKLOAD"

# Note current replica count for restoration
kubectl -n risingwave-2 get "$PG_WORKLOAD" -o jsonpath='{.spec.replicas}' > /tmp/rw2-postgres-replicas.txt

# Scale to 0
kubectl -n risingwave-2 scale "$PG_WORKLOAD" --replicas=0
# Wait for pods to terminate
kubectl -n risingwave-2 wait --for=delete pod -l app.kubernetes.io/name=postgresql --timeout=120s
```

## Step 6 — Delete the local-path PVC

```bash
kubectl -n risingwave-2 delete pvc "$PVC_NAME"
# Confirm gone
kubectl -n risingwave-2 get pvc | grep postgres || echo "PVC deleted as expected"
```

## Step 7 — Apply new PVC on ceph-block with Helm adoption labels

The Helm adoption labels are mandatory per [[feedback-helm-no-auto-pvc-restore]] — without them Helm won't recognize the new PVC and the deployment stays at replicas=0 forever.

Identify the HelmRelease name and namespace to populate the annotations:

```bash
HR_NAME=$(kubectl -n risingwave-2 get helmreleases.helm.toolkit.fluxcd.io | grep -i postgres | awk '{print $1}' | head -1)
echo "HelmRelease name: $HR_NAME"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC_NAME
  namespace: risingwave-2
  labels:
    app.kubernetes.io/instance: $HR_NAME
    app.kubernetes.io/name: postgresql
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: $HR_NAME
    meta.helm.sh/release-namespace: risingwave-2
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ceph-block
  resources:
    requests:
      storage: $PVC_SIZE
EOF

# Wait for binding
kubectl -n risingwave-2 wait --for=jsonpath='{.status.phase}'=Bound pvc/$PVC_NAME --timeout=60s
kubectl -n risingwave-2 get pvc "$PVC_NAME"
```

## Step 8 — Resume Flux + force reconcile

```bash
flux resume helmrelease "$HR_NAME" -n risingwave-2
flux resume kustomization <name> -n flux-system

flux reconcile helmrelease "$HR_NAME" -n risingwave-2 --force --with-source
```

## Step 9 — Scale Postgres back up + verify

```bash
PG_REPLICAS=$(cat /tmp/rw2-postgres-replicas.txt)
kubectl -n risingwave-2 scale "$PG_WORKLOAD" --replicas=$PG_REPLICAS

# Wait for Running + Ready
kubectl -n risingwave-2 wait --for=condition=Ready pod -l app.kubernetes.io/name=postgresql --timeout=300s

# Verify Postgres responds
POSTGRES_POD=$(kubectl -n risingwave-2 get pod -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}')
kubectl -n risingwave-2 exec -it "$POSTGRES_POD" -- psql -U postgres -c "\l" > /tmp/rw2-postgres-post.txt
diff /tmp/rw2-postgres-pre.txt /tmp/rw2-postgres-post.txt
# Diff should show databases intact (Postgres re-initialized as fresh DB OR restored from backup —
# IMPORTANT: if data must persist, restore from Velero BEFORE scaling up — see "Data persistence" below)
```

## Data persistence

**This runbook does NOT restore the Postgres data files from the old PVC by default.** The new ceph-block PVC starts EMPTY, and Postgres will initialize a fresh database. This is acceptable if:

- The Postgres in rw-2 is a transient metadata store that RW rebuilds (RisingWave operator may rebuild meta from compute nodes — verify this assumption first)
- OR the data is replicated elsewhere

**If data must persist**, before Step 5 (scale to 0) add a Velero PVC restore + manual data copy step. Easiest path:

```bash
# Velero file-level restore into a temp PVC, then rsync to new PVC after Step 7.
# See [[feedback-velero-restore-test-ns-servicemonitor-leak]] — remember to delete the
# restore-test ns when done.
```

**Decision point pre-execution:** confirm whether rw-2 Postgres is rebuildable (cheap) or holds operator state (must restore).

## Step 10 — RW-2 post-check

```bash
kubectl -n risingwave-2 get pods,svc,pvc > /tmp/rw2-post-1555.txt
diff /tmp/rw2-pre-1555.txt /tmp/rw2-post-1555.txt
# Expected diff: storageClassName=ceph-block on the Postgres PVC, restart counter reset to 0

# Confirm RW operator sees Postgres
kubectl -n risingwave-2 logs deploy/risingwave-operator --tail=50 | grep -i postgres
```

## Step 11 — Close the ticket

Update INFRA-1555 in Jira:

```
2026-MM-DD HH:MM UTC — Migration complete.
- Velero pre-backup: rw2-postgres-pre-migration-<TS> (Completed)
- Old PVC <name> on local-path: deleted
- New PVC <name> on ceph-block: bound, <size>
- Postgres pod: Running + Ready, psql \l returns expected databases
- RW-2 operator log clean, no Postgres connection errors
- Pre/post diff: only the storageClassName change
- Tim ack received pre-migration as courtesy; rw-2 namespace only, no impact on risingwave namespace
Closes the last local-path PVC on a production workload in rw-2. Matches the storage decision in ADR-001.
```

Transition to Done.

## Rollback (if migration goes sideways)

```bash
# Re-apply the original PVC
kubectl apply -f /tmp/rw2-postgres-pvc-original.yaml

# OR restore from Velero
velero restore create rw2-postgres-rollback-$TS \
  --from-backup rw2-postgres-pre-migration-$TS \
  --include-namespaces risingwave-2 \
  --wait
```

Then scale Postgres back up and verify pre-migration state.

## Related

- [[feedback-helm-no-auto-pvc-restore]] — Helm adoption labels mandatory on hand-applied PVC
- [[feedback-velero-restore-test-ns-servicemonitor-leak]] — delete restore-test ns if Velero restore used
- [[feedback-protect-rw-onprem-workload]] — rw-2 is ours but Tim courtesy ping is binding
- [[observability-phase0-locked-jun24]] — ADR-001 storage decision (ceph-block, not local-path)

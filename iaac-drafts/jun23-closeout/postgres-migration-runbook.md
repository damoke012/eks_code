# Runbook: rw-2 Postgres local-path → ceph-block migration

**Ticket**: INFRA-1545
**Time budget**: ~45-60 min including coordination
**Coordinator**: Doke (Cloud Platform) + Tim (RW owner) — `[[feedback-protect-rw-onprem-workload]]` mandates Tim sign-off before invasive RW changes
**Pre-flight required**: `/onprem-safety` skill checklist

## Why

The `data-postgres-postgresql-0` PVC in `risingwave-2` is bound to a 10Gi `local-path` PV pinned to `talos-wk-op-dev-6`. Node-local storage = single point of failure. With ceph-block now operational + Velero tested, we can migrate safely.

## Pre-checks

```bash
export KUBECONFIG=~/.kube/op-usxpress-dev.yaml

# 1. Postgres pod is healthy
kubectl -n risingwave-2 get pod postgres-postgresql-0 -o wide

# 2. Velero pre-backup of risingwave-2 (safety net)
velero backup create rw2-pre-postgres-migration --include-namespaces risingwave-2 --wait
velero backup describe rw2-pre-postgres-migration | grep Phase
# Phase: Completed

# 3. Confirm ceph-block headroom
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph df | head -5
# MAX AVAIL on replicapool should be > 50GB (we need 10GB)

# 4. Confirm RW operator + components are healthy first
kubectl -n risingwave-2 get pods -l app.kubernetes.io/instance=risingwave
```

## Step 1 — Coordinate with Tim

Brief Tim:
- ~30 min downtime on rw-2 (NOT his prod `risingwave` namespace)
- pg_dump → recreate PVC on ceph-block → pg_restore
- Velero backup as safety net (full rw-2 ns)
- Rollback: stop, restore from Velero backup if anything looks wrong

Get explicit acknowledgement before proceeding.

## Step 2 — Capture pre-state

```bash
# Save current Postgres state to /tmp for comparison
kubectl -n risingwave-2 exec postgres-postgresql-0 -- pg_dumpall -U postgres > /tmp/rw2-postgres-pre.sql
wc -l /tmp/rw2-postgres-pre.sql

# Save RW CR state (operator will need to re-reconcile)
kubectl -n risingwave-2 get risingwave risingwave -o yaml > /tmp/rw2-rw-cr.yaml

# Save Postgres helmrelease + pvc for reference
kubectl -n risingwave-2 get pvc data-postgres-postgresql-0 -o yaml > /tmp/rw2-pvc-pre.yaml
```

## Step 3 — Update HelmRelease values to ceph-block

Edit `manifests/op-usxpress-dev/postgres-helmrelease.yaml` in iaac-risingwave-2:

```yaml
spec:
  values:
    primary:
      persistence:
        enabled: true
        storageClass: ceph-block      # was: local-path
        size: 10Gi
```

Commit + PR + merge to main.

## Step 4 — Drop Postgres pod + reclaim PVC

```bash
# Scale Postgres to 0 (preserves PVC)
kubectl -n risingwave-2 scale statefulset postgres-postgresql --replicas=0
sleep 30
kubectl -n risingwave-2 get pods | grep postgres

# Take a final pg_dump from the dropped pod's PVC via a debug pod
# (mount the local-path PVC on a node-pinned debug pod, exfiltrate sql via stdin)

# Once data is captured, delete the PVC
kubectl -n risingwave-2 delete pvc data-postgres-postgresql-0

# Verify
kubectl -n risingwave-2 get pvc
```

## Step 5 — Scale back up, restore data

```bash
# Force Flux reconcile so the helmrelease re-creates the StatefulSet
flux reconcile kustomization risingwave -n flux-system 2>&1

# Postgres should come up with a new ceph-block PVC
sleep 60
kubectl -n risingwave-2 get pvc | grep postgres
kubectl -n risingwave-2 get pods | grep postgres

# Restore the dump
kubectl -n risingwave-2 cp /tmp/rw2-postgres-pre.sql postgres-postgresql-0:/tmp/restore.sql
kubectl -n risingwave-2 exec postgres-postgresql-0 -- psql -U postgres -f /tmp/restore.sql
```

## Step 6 — Verify RW components reconnect

```bash
# rw-2 components should re-connect to the new Postgres
sleep 60
kubectl -n risingwave-2 get pods -l app.kubernetes.io/instance=risingwave
kubectl -n risingwave-2 logs deploy/risingwave-meta-default --tail=20

# Query a RW table to confirm metadata is intact
psql -h <rw2-sql.usxpress.io> -p 5432 -U <user> -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';"
```

## Rollback

If anything goes wrong:

```bash
# Restore from the Velero pre-migration backup
velero restore create rw2-postgres-rollback \
  --from-backup rw2-pre-postgres-migration \
  --include-namespaces risingwave-2 \
  --wait

# Verify
kubectl -n risingwave-2 get pvc,pods
```

The Velero backup captures the local-path PVC content via Kopia file-system backup (validated 2026-06-23 — restore exercised successfully). Restore will recreate the PVC and StatefulSet to pre-migration state.

## Post-checks

```bash
# Compare row counts pre/post
diff <(grep -c "INSERT INTO" /tmp/rw2-postgres-pre.sql) \
     <(kubectl -n risingwave-2 exec postgres-postgresql-0 -- psql -U postgres -tc "SELECT count(*) FROM pg_stat_user_tables;")

# Confirm ceph-block usage
kubectl -n risingwave-2 get pvc | grep postgres
# STORAGECLASS should be ceph-block

# Confirm Tim's RW namespace is undisturbed
kubectl -n risingwave get pods | wc -l
# Should match pre-migration count
```

## Tickets

- INFRA-1545 (this ticket)
- Refs: session_state_jun23.md, feedback-protect-rw-onprem-workload

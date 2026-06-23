# INFRA-1545: Migrate rw-2 Postgres from local-path to ceph-block

**Type**: Task
**Priority**: High (restore-readiness)
**Component**: rw-2 / risingwave-2
**Reporter**: Doke
**Created**: 2026-06-23

## Problem

The `data-postgres-postgresql-0` PVC in `risingwave-2` namespace is bound to a 10Gi `local-path` PV pinned to a single worker node (`talos-wk-op-dev-6`).

Failure scenarios:
- If `talos-wk-op-dev-6` dies → Postgres data is gone forever (local-path is node-local)
- If worker disk fails → same
- Velero can back this up via Kopia file-system backup (now operational as of 2026-06-23), but RECOVERY-WITHOUT-VELERO is not possible

This is a single-point-of-failure that contradicts our restore-readiness goal.

## Scope

Migrate the Postgres PVC to `ceph-block` (Rook-Ceph RBD), which has 3-way replication across workers. Ceph-block is operational and proven (Prometheus + rw-2 prometheus-server migrated 2026-06-23).

## Migration approach

NOT in-place. Needs careful ceremony:

1. **Pre**: trigger a Velero backup of `risingwave-2` namespace (snapshot for safety net)
2. **Coordinate with Tim**: rw-2 is RisingWave's metadata store. Brief downtime needed.
3. **pg_dump** from the current postgres pod to a temp PVC or to a S3 location
4. **Scale Postgres StatefulSet to 0**
5. **Delete** the local-path PVC + PV
6. **Update** the postgres-helmrelease.yaml's `persistence.storageClass` to `ceph-block`
7. **Apply** via Flux → new PVC binds to ceph-block
8. **pg_restore** the dump into the new PVC
9. **Scale Postgres StatefulSet back to 1**
10. **Verify** rw-2 operator + components reconnect cleanly
11. **Post**: take another Velero backup of the new state

## Acceptance criteria

- `data-postgres-postgresql-0` PVC bound to `ceph-block` SC
- `rw-2` operator + meta + compute + frontend + compactor all Running 0 errors
- A test query / metadata read confirms data integrity
- Velero backup of risingwave-2 ns completes Phase: Completed

## Constraints

- **Do NOT touch Tim's `risingwave` namespace** — different cluster, different SPOFs, his to manage
- Coordinate the maintenance window with Tim (rw-2 is shared CICD env, not just our toy)
- Brief downtime expected: ~30-45 min

## Estimate

~1 hour active work + coordination

## Refs

- session_state_jun23.md — restore-readiness audit findings
- [`feedback-protect-rw-onprem-workload`](../../memory/feedback_protect_rw_onprem_workload.md)
- Local-path PV nodeAffinity confirmed via `kubectl get pv $(kubectl -n risingwave-2 get pvc data-postgres-postgresql-0 -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.nodeAffinity}'`

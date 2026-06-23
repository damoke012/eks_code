# Ceph mgr OOMKill loop on default 512Mi memory limit

**Category**: 02-storage
**First seen**: 2026-06-23 op-usxpress-dev (135 mgr OOMKills in 16 hours)
**Severity**: Ceph mgr unavailable in crashloop → pg_autoscaler stops, telemetry stops, prometheus exporter stops, eventually HEALTH_WARN

## Symptom

`kubectl -n rook-ceph get pods -l app=rook-ceph-mgr` shows high RESTARTS count climbing rapidly:

```
NAME                              READY   STATUS    RESTARTS         AGE
rook-ceph-mgr-a-...               3/3     Running   67 (5m ago)      16h
rook-ceph-mgr-b-...               3/3     Running   68 (3m ago)      16h
```

`kubectl -n rook-ceph describe pod -l app=rook-ceph-mgr | grep -A 1 "Reason:"`:

```
Reason:       OOMKilled
```

`ceph -s` (from rook-ceph-tools) may eventually show HEALTH_WARN as mgr modules fail to converge:

```
HEALTH_WARN
  manager daemon "a" is unresponsive
```

## Why

The default Rook CephCluster CR sets mgr resources at:
- requests: 100m CPU / 256Mi memory
- limits: 500m CPU / **512Mi memory**

512Mi is too small for any non-trivial Ceph cluster. The mgr loads:
- PG metadata (grows with object count + replica count + erasure coding overhead)
- Scrub history
- Crash logs (we had 9 historical crashes on op-usxpress-dev)
- Prometheus exporter state
- Telemetry / heatmap modules
- Rook + pg_autoscaler + balancer modules

For op-usxpress-dev (modest workload):  4-second OOMKill cycles within hours of normal operation. 135 restarts in 16h.

## Fix

In `infrastructure/rook-ceph-cluster/cephcluster.yaml`:

```yaml
spec:
  resources:
    mgr:
      requests: { cpu: 200m, memory: 1Gi }
      limits:   { cpu: 1000m, memory: 2Gi }
```

The Rook operator rolls mgr pods one at a time (active first, then standby). Cluster stays HEALTH_OK during roll — mons are independent of mgr.

## Detection

```bash
# RESTARTS column > 10 within 24h = OOM is likely
kubectl -n rook-ceph get pods -l app=rook-ceph-mgr

# Confirm OOMKilled
kubectl -n rook-ceph describe pod -l app=rook-ceph-mgr | grep -B 1 -A 2 "Reason:.*OOMKilled"

# Look at memory usage trend
kubectl -n rook-ceph top pod -l app=rook-ceph-mgr --containers
```

## Recovery

Bump the values, apply via Flux, wait for the rolling restart.

```bash
# Watch the migration
kubectl -n rook-ceph get pods -l app=rook-ceph-mgr -w

# Verify post-roll
kubectl -n rook-ceph get pods -l app=rook-ceph-mgr
# Both mgr-a + mgr-b RESTARTS should stop climbing (no further OOMKills)
```

## How to apply to QA / PROD

- Bake `mgr: limits.memory: 2Gi` into the CephCluster CR for ALL clusters — don't ship a known-too-small default
- Set `requests.memory: 1Gi` so the scheduler reserves capacity
- For larger clusters (PROD), 4Gi limit is reasonable
- Monitor via Prometheus: `container_memory_working_set_bytes{container="mgr"}` should stay below ~80% of limit

## Reference incident

- op-usxpress-dev 2026-06-23 PR #54 — bumped 512Mi → 2Gi after 135 OOMKills/16h
- See also: [`feedback-ceph-mgr-memory-default-too-small`](../../memory/feedback_ceph_mgr_memory_default_too_small.md)
- Ceph docs sizing recommendations are vague; lean larger for any cluster with > 1 pool or > 10 OSDs

## Related

- Rook upstream issue (file if not already): chart defaults should target 2Gi mgr limit
- `[[ROOK-CEPH-IMPLEMENTATION-2026-06-19]]` — architecture foundation

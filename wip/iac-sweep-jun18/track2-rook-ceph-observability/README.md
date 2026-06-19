# Track 2 — Rook-Ceph observability + restore runbook

**Why this exists:** the safe re-roll (PRs #37 + #16) brought Rook up but with no monitoring + no documented restore procedure. We don't want to wait for Idris's 9:50 ET ping to learn that Ceph is HEALTH_ERR.

## Files

| File | Purpose | Target repo / path |
|---|---|---|
| `prometheusrule-ceph.yaml` | Alerts on HEALTH_WARN/ERR, mon quorum, OSDs down, capacity | `iaac-talos-flux-platform/infrastructure/rook-ceph-cluster/` |
| `servicemonitor-ceph.yaml` | Scrape rook-ceph-mgr metrics on :9283 | `iaac-talos-flux-platform/infrastructure/rook-ceph-cluster/` |
| `cephcluster-monitoring-patch.yaml` | Kustomize patch to enable `dashboard` + `monitoring` on CephCluster CR | `iaac-talos-flux-platform/infrastructure/rook-ceph-cluster/` (added to `patches:`) |
| `restore-runbook.md` | 5-scenario restore + recovery procedures | `docs/runbooks/rook-ceph-restore.md` |

## PR sequence

1. PR `cephcluster-monitoring-patch.yaml` FIRST — enables the mgr metrics endpoint
2. Wait for CephCluster to reconcile (`kubectl -n rook-ceph get cephcluster` PHASE=Ready)
3. PR `servicemonitor-ceph.yaml` + `prometheusrule-ceph.yaml` together — start scraping + alerting
4. PR `restore-runbook.md` separately (eks_code docs/ tree)

## Validation after merge

```bash
# 1. mgr metrics endpoint
kubectl -n rook-ceph get svc rook-ceph-mgr
kubectl -n rook-ceph port-forward svc/rook-ceph-mgr 9283:9283 &
curl -s http://localhost:9283/metrics | grep ceph_health_status

# 2. ServiceMonitor picked up
kubectl -n rook-ceph get servicemonitor rook-ceph-mgr
# Then check Prometheus UI for the target

# 3. PromRule loaded
kubectl -n rook-ceph get prometheusrule rook-ceph-cluster
# Verify no syntax errors in the rule by checking Prometheus's rule list endpoint
```

## Risks / caveats

- The `metricsDisabled: false` setting in the CephCluster patch causes Rook operator to also try to create its own ServiceMonitor. The label selector on Prometheus typically picks one — but to avoid duplicate scrapes, set `metricsDisabled: true` later and rely only on the IaC-managed ServiceMonitor. Start with both, observe, then disable Rook's.
- The `ceph_*` metric names assume mgr's Prometheus exporter is the standard one. If on a custom Rook version, validate metric names by hitting `:9283/metrics` first.
- Some PromRules (especially `CephMonDown`) use heuristics that may need tuning after first deploy — observe over a week, adjust thresholds.

## Related lessons codified

- [[incident_2026_06_17_cp_oom_cascade]] — the placement disaster that drove the safe re-roll
- [[feedback_protect_rw_onprem_workload]] — RW must never be on Ceph by accident
- `/onprem-safety` Rule 1 (placement), Rule 5 (RW awareness)

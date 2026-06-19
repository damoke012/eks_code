# Phase 1 — Prom baseline standardization (PR drafts)

**Ticket:** [INFRA-1516](https://usxpress.atlassian.net/browse/INFRA-1516)

**Order of operations (low-risk first):**

1. **PR 1 — `cluster` externalLabel** ([helmrelease.yaml.diff](helmrelease.yaml.diff))
   - Single-line additive change. Zero behavior change today; gates Phase 5 remote_write.
   - Repo: `iaac-talos-flux-platform op-dev`, `infrastructure/prometheus/helmrelease.yaml`.

2. **PR 2 — Kyverno ClusterPolicy: auto-add `prometheus_ingest=true` to ServiceMonitor + PodMonitor** ([kyverno-prometheus-ingest-label.yaml](kyverno-prometheus-ingest-label.yaml))
   - Additive on admission only — opt-out via explicit `prometheus_ingest=false`.
   - Path: `iaac-talos-flux-platform op-dev/infrastructure/kyverno-policies/prometheus-ingest-label.yaml`.

3. **PR 3 — Kyverno ClusterPolicy: auto-add `cluster=op-usxpress-dev` to Pods** ([kyverno-cluster-label.yaml](kyverno-cluster-label.yaml))
   - Belt-and-suspenders for workload metrics; chart-level externalLabel covers Prom-emitted series, this covers Pod-emitted metrics.
   - Path: `iaac-talos-flux-platform op-dev/infrastructure/kyverno-policies/cluster-label.yaml`.

4. **Backfill (one-time)** ([backfill-existing-sm.sh](backfill-existing-sm.sh))
   - Label any pre-existing ServiceMonitor / PodMonitor that admission didn't catch.
   - WSL2 only — codespace can't reach cluster.

5. **PR 4 — Flip `serviceMonitorSelector` to `prometheus_ingest=true`** ([helmrelease.yaml.diff-v2](helmrelease.yaml.diff-v2))
   - Run AFTER step 4 confirms all desired SMs are labeled.
   - Cloud convention; needed only for parity / symmetry with cloud setup.

## Why this order

The on-prem HelmRelease currently has `serviceMonitorSelectorNilUsesHelmValues: false` (matches every SM in any namespace). If we add a selector before backfill, anything un-labeled stops being scraped — INFRA-1503 alerts could go silent. The phased order avoids that regression.

## Validation after each PR

| PR | Validation command (WSL2) |
|---|---|
| 1 | `kubectl -n prometheus get prometheus -o yaml \| yq '.spec.externalLabels'` |
| 2 | `kubectl apply --dry-run=server -f new-sm.yaml` and confirm mutated label appears |
| 3 | `kubectl apply --dry-run=server -f new-pod.yaml` and confirm mutated label appears |
| 4 | `kubectl get servicemonitor -A -o json \| jq '.items[] \| select(.metadata.labels.prometheus_ingest != "true") \| .metadata.name'` returns empty |
| 5 | `kubectl -n prometheus get prometheus -o yaml \| yq '.spec.serviceMonitorSelector'` shows the new matchLabels; verify all 12 INFRA-1503 alerts still loaded |

## Rollback per PR

| PR | Rollback |
|---|---|
| 1 | Revert single line; no resource churn |
| 2 | `kubectl delete clusterpolicy add-prometheus-ingest-label` (additive policy; deleting it = pre-PR state) |
| 3 | `kubectl delete clusterpolicy add-cluster-label` (same) |
| 4 | Re-run backfill or wait for Kyverno to label freshly-applied SMs |
| 5 | Revert selector to `{}` (matches everything) |

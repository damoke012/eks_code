# PR #75 + #76 — the Grafana split-out of #73 (2026-07-10)

Idris split #73's good parts out as recommended. Both by ifagbemi, base op-dev.

## PR #76 — feat(grafana): add RisingWave streaming dashboards
- `split/rw-streaming-dashboards` @ 7e66bd5. +67,500/−1, 11 files. mergeable=MERGEABLE.
- Content: dashboards as ConfigMaps in `grafana` ns (`dashboard-risingwave-streaming.yaml` 60,563 lines, `-overview` 6,164) + 6 docs.
- RW references are docs/PromQL only — NO manifest applied into `risingwave` ns. **No Tim coord. No secret/argocd/NodePort.**
- **Verdict: approve pending ONE check** — `dashboard-risingwave-streaming.yaml` byte size < 1 MiB (ConfigMap hard limit). If over, split the dashboard or load via sidecar/URL, not an inline ConfigMap. (This is the real issue #73's ServerSideApply was masking — SSA doesn't raise the 1 MiB limit.)

## PR #75 — fix(grafana): resolve No Data by pinning Prometheus nameOverride
- `split/grafana-no-data` @ 9953ad1. +24/−2: `infrastructure/prometheus/helmrelease.yaml` (+20), `infrastructure/grafana/helm-values-configmap.yaml` (+4).
- **mergeable=CONFLICTING → Idris must rebase on op-dev first.**
- **Verdict: hold** until (a) rebased, and (b) diff confirmed NOT to revert June INFRA-1520 fixes in helmrelease.yaml: Prometheus memory 1Gi→4Gi (WAL-replay OOM), node-exporter hostNetwork:false, datasource UID.

## Relationship to #73
#73 stays CLOSE-recommended. #75/#76 are the clean replacements for its observability commits. The Argo CD repo-sync part of #73 is NOT replaced (and shouldn't be — Flux `risingwave-onprem` already does it).

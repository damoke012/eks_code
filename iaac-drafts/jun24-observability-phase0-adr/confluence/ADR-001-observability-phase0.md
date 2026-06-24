# Observability Phase 0 — Decision Lock (op-usxpress-dev)

**Status:** Accepted  
**Date:** 2026-06-24  
**Author:** Doke (Cloud Platform Team)  
**Sign-off (cluster owner):** Doke — 2026-06-24  
**Jira:** INFRA-1515 (Done)  
**Source ADR in repo:** `variant-inc/iaac-talos-flux-platform` → `op-dev/docs/decisions/ADR-001-observability-phase0.md`

## Why this page exists

op-usxpress-dev is the production-replacement on-prem Talos cluster. The cloud platform team operates `iaac-monitoring` for AWS workloads; this ADR records the 4 decisions that lock how we mirror that posture on-prem. Implementation lives in subsequent phase tickets (INFRA-1516..1524). This page is the durable record so engineers searching Confluence find the rationale without having to chase Jira comments.

## The 4 Phase 0 decisions

### 1. Metrics backend = kube-prometheus-stack

We adopt the upstream `prometheus-community/kube-prometheus-stack` chart, currently v72.9.1 (app v3.4.1). It bundles Prometheus Operator + Prometheus + Alertmanager + node-exporter + kube-state-metrics + Operator CRDs (ServiceMonitor, PodMonitor, PrometheusRule, AlertmanagerConfig).

**Why:** same chart family as cloud `iaac-monitoring`; Operator CRDs let workload teams ship their own scrape configs without platform gate-keeping; mature upgrade path.

**Rejected:** standalone `prometheus@29.x` (no Operator CRDs), VictoriaMetrics/Thanos/Mimir (premature, divergent), managed Grafana Cloud / Datadog (cost + cross-VPN egress + violates on-prem outage-independence design).

**Operational locks:**

- Storage: `ceph-block`, 20Gi PVC
- Memory: 4Gi limit (1Gi was OOMKilled during WAL replay + scrape pool init)
- ServiceMonitor discovery: cluster-wide (`serviceMonitorSelectorNilUsesHelmValues: false`)
- CP-safety: explicit nodeAffinity + empty tolerations (per `/onprem-safety` Rule 1)
- node-exporter: `hostNetwork: false` while legacy `prometheus@29.x` charts still bind hostPort 9100 in `risingwave-2/` and `monitoring/` namespaces
- Namespace: `prometheus`, PSA `enforce: privileged` (required for node-exporter hostPath mounts)

### 2. Grafana strategy = chart + sidecar pattern + AAD SSO

We adopt the upstream `grafana/grafana` chart v11.4.0 with:

- **Dashboard sidecar** — auto-imports ConfigMaps labeled `grafana_dashboard: "1"` from all namespaces. Workload teams ship dashboards as Kubernetes resources in their own namespace.
- **Kyverno folder mutation** — `ClusterPolicy` annotates each dashboard CM with `grafana_folder: <namespace>` so dashboards land in folders matching their owner.
- **Datasource sidecar + chart-shipped Prometheus** — `uid: prometheus` pinned in values.yaml so dashboards' `{"uid": "prometheus"}` references resolve. `deleteDatasources` block bypasses `editable: false` on reprovision.
- **Azure AD OIDC SSO** — USXPress tenant `bbb5a66d-5c9f-482a-969a-a40304b6bc8d`. Config skeleton shipped with `enabled: false`; live login waits on OAuth app registration (INFRA-1558).
- **Storage** — `ceph-block`, 10Gi PVC.
- **Ingress** — `grafana.op-dev.usxpress.io` via Istio Gateway + cert-manager wildcard.

**Rejected:** Grafana Cloud / Datadog UI (cost + outage-independence), manual dashboard imports via UI (not IaC), local username/password auth (everyone has corporate AAD), auto-generated datasource UID (breaks dashboard refs).

### 3. Alert routing pattern = Prometheus → Alertmanager → PagerDuty → Freshservice

We mirror cloud's routing topology. Alertmanager (chart-bundled) handles grouping/silencing/inhibition; PagerDuty handles escalation policies + on-call rotation; Freshservice handles ticket lifecycle.

**Wiring status:** **NOT** shipped in Phase 0. Default receiver is empty. Severity routing rules + on-call schedule wiring are tracked under **INFRA-1517** (Phase 2).

**Rejected:** direct Prometheus → Freshservice (no grouping/silencing), direct Prometheus → Slack/Teams (not the corporate incident channel; legal/audit prefers PD+FS trail), re-use cloud Alertmanager (adds cross-VPN dependency, violates outage-independence).

### 4. OTel scope = OUT OF SCOPE for Phase 0-3

We do **not** ship OpenTelemetry collector + traces/logs pipeline on op-usxpress-dev in Phase 0 through Phase 3.

**Why:** cloud `iaac-monitoring` does not currently run OTel; adding it on-prem creates a divergence the cloud team hasn't validated. Workloads needing distributed traces today already route directly to cloud Honeycomb/Datadog via cross-cluster egress — same path as on AWS workloads. Operating two different observability stacks for the same engineers is the wrong default.

**Revisit trigger:** when cloud `iaac-monitoring` adds an OTel collector to its canonical pattern, op-usxpress-dev follows within one sprint.

**Sign-off on out-of-scope:** Doke (cluster owner) — 2026-06-24. With Vibin's departure, cross-cluster sign-off authority transfers to Matt Hagden / Steve Duck; this decision will be cross-checked at the next cloud platform sync.

## Implementation status

| Decision | Status |
|---|---|
| 1 (Backend) | Operational — all 7 workers exporting node metrics, KSM live, cAdvisor scraping |
| 2 (Grafana) | Operational — `https://grafana.op-dev.usxpress.io` baseline dashboard rendering with live data (10 nodes, 219 pods, 35% CPU, 29% memory). SSO skeleton in place, awaits INFRA-1558 |
| 3 (Routing) | Pattern locked, wiring deferred to INFRA-1517 |
| 4 (OTel) | Decision logged, no work |

## Downstream tickets

| Ticket | Scope | Status |
|---|---|---|
| INFRA-1516 | node-exporter & KSM | Done |
| INFRA-1517 | Alertmanager wiring + PD routing rules | Phase 2 — not started |
| INFRA-1518 | Additional dashboards beyond baseline | Open |
| INFRA-1519 | PrometheusRule library + SLO rules | Open |
| INFRA-1520 | Grafana deployment | Done (2026-06-23) |
| INFRA-1521..1524 | Successive observability phases | Open |
| INFRA-1558 | Azure AD OAuth app registration (Grafana SSO unblock) | Blocked on Application Administrator role |

## Operational gotchas captured during Phase 0

These will be added to the on-prem troubleshooting catalog (`variant-inc/iaac-talos/deploy/docs/troubleshooting/`):

1. **kube-prometheus-stack 1Gi memory OOMKills** during WAL replay + scrape pool init with 30+ ServiceMonitors. Bump to 4Gi.
2. **Grafana datasource UID auto-generation breaks dashboard `{uid: prometheus}` references.** Pin UID + use `deleteDatasources` to bypass `editable: false`.
3. **node-exporter hostPort 9100 collision** in mixed-chart environments. Set `hostNetwork: false` on the new chart.
4. **Velero restore-test ns leaks ServiceMonitors** — duplicate scrape targets after auto-discovery. Always `kubectl delete ns restore-test` after a restore exercise.
5. **Helm doesn't auto-restore user-deleted PVCs.** StorageClass migrations need manual `kubectl apply` with Helm adoption labels.

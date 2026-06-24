# ADR-001 — Observability Phase 0 decisions for op-usxpress-dev

| Field | Value |
|---|---|
| Status | **Accepted** |
| Date | 2026-06-24 |
| Cluster | op-usxpress-dev (on-prem Talos / vSphere) |
| Jira | [INFRA-1515](https://usxpress.atlassian.net/browse/INFRA-1515) — closed Done |
| Author | Doke (Cloud Platform Team) |
| Sign-off | Doke (cluster owner) — 2026-06-24 |
| Supersedes | none |
| Superseded by | none |

## Context

op-usxpress-dev is the production-replacement on-prem Talos cluster (3 CP × 8GB + 7 workers × 4GB, v1.32.0). It hosts cloud-platform-owned platform services (cert-manager, Istio, Rook-Ceph, Velero, External-DNS, External-Secrets, Kyverno, Reloader) plus tenant workloads (RisingWave, brands-api, attrition-api, geo-handler).

Until now, observability for op-usxpress-dev has been ad-hoc: a legacy `prometheus@29.x` chart in `risingwave-2/` and `monitoring/` namespaces, no central Grafana, no alert routing to the corporate stack. The cloud platform team operates `iaac-monitoring` for AWS workloads; we want on-prem to mirror that posture so on-call engineers see one stack across hybrid infrastructure.

This ADR locks the 4 Phase 0 dimensions of the observability work. Implementation lives in subsequent phase tickets (INFRA-1516..1524). Phase 0's job is **decisions**, not implementation.

## Decisions

### Decision 1 — Metrics backend: kube-prometheus-stack

**Chosen:** `prometheus-community/kube-prometheus-stack` chart, currently v72.9.1 (app v3.4.1).

Bundles Prometheus Operator + Prometheus server + Alertmanager + prometheus-node-exporter + kube-state-metrics + Operator CRDs (ServiceMonitor, PodMonitor, PrometheusRule, AlertmanagerConfig).

**Why:**
- Same chart family as cloud `iaac-monitoring`. Engineers operate one mental model.
- Operator CRDs let workload teams ship their own `ServiceMonitor` resources without platform-team gate-keeping.
- Mature upgrade path; chart releases track upstream Prometheus.

**Rejected alternatives:**
- **Standalone `prometheus` chart (v29.x)** — what we had. No operator CRDs, no ServiceMonitor pattern, can't auto-discover scrape targets. Legacy installs remain in `risingwave-2/` and `monitoring/` until retired.
- **VictoriaMetrics / Thanos / Mimir** — divergence from cloud, no team experience, premature for current scale (~10 nodes).
- **Managed Grafana Cloud / Datadog** — cost + cross-VPN egress + the cluster is supposed to be independent of cloud per [[onprem-aws-outage-independence design]].

**Operational locks:**
- Storage: `ceph-block` StorageClass, 20Gi PVC.
- Memory: 4Gi limit (1Gi was OOMKilled during WAL replay + ServiceMonitor scrape pool init; verified 2026-06-24 via PR #69).
- ServiceMonitor discovery: `serviceMonitorSelectorNilUsesHelmValues: false` — auto-pick up SMs from every namespace.
- CP-safety: `nodeAffinity: DoesNotExist on node-role.kubernetes.io/control-plane`, `tolerations: []` (per [[onprem-safety]] Rule 1; 2026-06-17 OOM cascade enforces this).
- Namespace: `prometheus`, PSA `enforce: privileged` (required for node-exporter hostPath mounts).
- node-exporter: `hostNetwork: false` while legacy `prometheus@29.x` charts still bind hostPort 9100 on every worker. Revert to `hostNetwork: true` once legacy charts retired.
- Repo: `variant-inc/iaac-talos-flux-platform`, path `op-dev/infrastructure/prometheus/`.

### Decision 2 — Grafana strategy: Helm chart + sidecar pattern

**Chosen:** `grafana/grafana` chart v11.4.0 with:
- **Dashboard sidecar** — auto-imports `ConfigMap` resources labeled `grafana_dashboard: "1"` from all namespaces (`SEARCH_NAMESPACE: ALL`).
- **Folder mutation via Kyverno** — `ClusterPolicy` adds `grafana_folder: <namespace>` annotation to every dashboard CM so dashboards land in folders matching their owning namespace (e.g., `monitoring/dashboard-x` lands in folder `monitoring`).
- **Datasource sidecar + chart-shipped Prometheus** — `uid: prometheus` pinned in `values.yaml` so dashboards' `{"uid": "prometheus"}` references resolve. `deleteDatasources` block bypasses `editable: false` on UID reprovision (gotcha).
- **Azure AD OIDC SSO** — config skeleton shipped with `enabled: false` until OAuth app registration lands (blocked on INFRA-1558 — needs Application Administrator on USXPress tenant `bbb5a66d-5c9f-482a-969a-a40304b6bc8d`).
- **Storage** — `ceph-block`, 10Gi PVC. NOTE: Helm doesn't auto-restore user-deleted PVCs; migrations require manual `kubectl apply` with Helm adoption labels (`app.kubernetes.io/managed-by: Helm`, `meta.helm.sh/release-name`, `meta.helm.sh/release-namespace`).
- **Ingress** — `grafana.op-dev.usxpress.io` via Istio Gateway + cert-manager (uses [[onprem-per-team-cert-pattern]] wildcard).
- **Admin credentials** — AWS Secrets Manager `op-usxpress-dev/platform/grafana`.

**Why:**
- Sidecar discovery means workload teams ship dashboards as Kubernetes resources in their own namespaces, no Grafana admin involvement.
- Kyverno folder mutation enforces an org pattern (folder = namespace) without manual maintenance.
- Pinned UID `prometheus` makes dashboards portable across clusters (cloud Grafana can pin the same UID).
- Azure AD SSO replaces local Grafana auth, matches USXPress corporate identity.

**Rejected alternatives:**
- **Grafana Cloud / Datadog UI** — see Decision 1 rationale (cost + outage-independence).
- **Manual dashboard imports via UI** — operationally wrong; dashboards aren't IaC.
- **Local username/password auth** — every dev has a corporate AAD identity; no point creating a second one.
- **Auto-generated datasource UID** — silently breaks dashboards (chart default produces hashes like `PBFA97CFB590B2093` that don't match the `prometheus` UID dashboards reference).

**Operational locks:**
- Repo: `variant-inc/iaac-talos-flux-platform`, path `op-dev/infrastructure/grafana/`.
- Baseline dashboard: "Kubernetes Cluster Overview (op-usxpress-dev)" — Nodes / Pods total / Cluster CPU% / Cluster Memory% stat panels + CPU/Memory per node + Pods per namespace timeseries. Ships as ConfigMap. Verified rendering 2026-06-24.

### Decision 3 — Alert routing: pattern locked, wiring deferred

**Chosen pattern:** Prometheus → Alertmanager (chart-bundled) → PagerDuty webhook receiver → PagerDuty service → Freshservice ticket via the PagerDuty-Freshservice integration.

**Why:**
- Mirrors cloud `iaac-monitoring` routing topology — on-call engineers see one paging stack.
- PagerDuty + Freshservice are already the corporate incident response stack (see [[reference-usx-incident-stack]]); no new vendors.
- Alertmanager's silencing + grouping + inhibition cover the routing logic; PagerDuty handles escalation policies and on-call rotation; Freshservice handles ticket lifecycle.

**Wiring status:** **NOT** shipped in Phase 0. Default receiver remains empty. Severity routing rules + on-call schedule wiring are tracked under [INFRA-1517](https://usxpress.atlassian.net/browse/INFRA-1517) (Phase 2).

**Rejected alternatives:**
- **Direct Prometheus → Freshservice** — no grouping, no silencing, no escalation; spammy.
- **Direct Prometheus → Slack/Teams** — not the corporate incident channel; legal/audit prefers PD+FS ticket trail.
- **Re-use cloud Alertmanager** — adds cross-VPN dependency; violates [[onprem-aws-outage-independence]].

### Decision 4 — OTel scope: out of scope for Phase 0-3

**Chosen:** OpenTelemetry collector + traces/logs pipeline is **OUT OF SCOPE** for op-usxpress-dev Phase 0 through Phase 3.

**Why:**
- Cloud `iaac-monitoring` does **not** currently run an OpenTelemetry collector. Adding one on-prem creates a divergence the cloud team hasn't validated.
- Workloads needing distributed traces today already route directly to cloud Honeycomb/Datadog endpoints via cross-cluster egress — same path as on AWS workloads.
- Adding OTel here without cloud parity would mean operating two different observability stacks for the same engineers.

**Revisit trigger:** When cloud `iaac-monitoring` adds an OTel collector to its canonical pattern, op-usxpress-dev follows within one sprint.

**Sign-off on out-of-scope:** Doke (cluster owner) — 2026-06-24. With Vibin's departure, cloud platform sign-off authority for cross-cluster decisions transfers to Matt Hagden / Steve Duck; this ADR's OTel decision is recorded as a Knight-Swift / on-prem team decision and will be cross-checked at the next cloud platform sync.

**Rejected alternatives:**
- **Ship OTel collector now, point workloads at on-prem backend** — premature; no on-prem traces backend exists.
- **Add OTel as a Phase 4 ticket without a revisit trigger** — leaves the work to drift; better to gate on cloud parity.

## Implementation status as of this ADR

| Decision | Status |
|---|---|
| 1 (Backend) | **Operational** — running on ceph-block, 4Gi mem, all 7 workers exporting node metrics + KSM + cAdvisor |
| 2 (Grafana) | **Operational** — `https://grafana.op-dev.usxpress.io` returns baseline dashboard with live cluster data (10 nodes, 219 pods, 35% CPU, 29% memory at the time of writing). SSO skeleton in place, awaits INFRA-1558 |
| 3 (Routing) | **Pattern locked, wiring deferred** to INFRA-1517 |
| 4 (OTel) | **Decision logged, no work** |

## Downstream tickets

| Ticket | Scope | Status |
|---|---|---|
| INFRA-1516 | node-exporter & KSM | Done (shipped via Phase 0 implementation chain) |
| INFRA-1517 | Alertmanager wiring + PD routing rules | Phase 2 — not started |
| INFRA-1518 | Additional dashboards beyond baseline | Open |
| INFRA-1519 | PrometheusRule library + SLO rules | Open |
| INFRA-1520 | Grafana deployment | Done (2026-06-23) |
| INFRA-1521..1524 | Successive phases — see Observability plan jun02 | Open |
| INFRA-1558 | Azure AD OAuth app registration (Grafana SSO unblock) | Blocked on IT lead / Application Administrator role |

## Operational gotchas captured during Phase 0 (catalog follow-up)

These will be added to `variant-inc/iaac-talos/deploy/docs/troubleshooting/` as a follow-up PR:

1. **kube-prometheus-stack 1Gi memory OOMKills** during WAL replay + scrape pool init with 30+ ServiceMonitors. Bump to 4Gi.
2. **Grafana datasource UID auto-generation breaks dashboard `{uid: prometheus}` references.** Pin UID + use `deleteDatasources` to bypass `editable: false` on reprovision.
3. **node-exporter hostPort 9100 collision in mixed-chart envs** (kube-prometheus-stack + legacy standalone prometheus). Set `hostNetwork: false` on the new one.
4. **Velero restore-test ns leaks ServiceMonitors** — `serviceMonitorSelectorNilUsesHelmValues: false` then auto-discovers them as duplicate scrape targets. Always `kubectl delete ns restore-test` after a restore exercise.
5. **Helm doesn't auto-restore user-deleted PVCs.** StorageClass migration via PVC delete requires manual `kubectl apply` with Helm adoption labels on the replacement.

## References

- [Observability plan jun02](../../../wip/observability/PLAN.md) — full 9-phase mirror of cloud `iaac-monitoring`
- Cloud `iaac-monitoring` repo (canonical pattern source)
- [On-prem AWS outage independence design](../../../docs/designs/design_doc_onprem_aws_outage_independence.md)
- [/onprem-safety skill](../../../.claude/skills/onprem-safety/SKILL.md) — Rule 1 (CP exclusion) drove DaemonSet placement constraints in Decision 1

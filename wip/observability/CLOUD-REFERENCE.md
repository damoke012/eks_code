# Cloud monitoring stack — reference for on-prem replication

*Inspected 2026-06-02. Source: `variant-inc/iaac-monitoring` repo (head `acc152e`, kubecost upgrade merge).*

## Stack inventory

| Component | Chart | Role |
|---|---|---|
| Prometheus | `kube-prometheus-stack` (Prom Community) | Scraper. Alertmanager OFF, Grafana OFF, defaultRules OFF. Pure scrape. |
| VictoriaMetrics | `victoria-metrics-distributed` (VM upstream) | Long-term storage + cluster-wide query. Multi-AZ, multi-shard. |
| vmauth | Bundled in VM chart | Gateway for read/write into VM. Two endpoints: global-read + global-write. |
| vmalert | Bundled in VM chart | Rule engine querying VM (not Prom). **`notifier.blackhole: "true"` — alerts dropped today.** |
| Grafana | Grafana official chart | UI. Azure AD SSO, EFS persistence, **unified_alerting.enabled: true**. |
| Pyroscope | Pyroscope chart | Continuous profiling. |
| OTel | Custom chart (OTel collectors as DaemonSet + Deployment) | Traces aggregator + events collector + external/internal exporters. |
| ClickHouse | Custom chart | Trace + log storage backend. Reached via `clickhouse.dpl.usxpress.io:9000`. |
| Prometheus blackbox exporter | `prometheus-blackbox-exporter` | URL probing. |
| Prometheus adapter | `prometheus-adapter` | Custom metrics for HPA. |
| Kubecost | Kubecost chart | Cost monitoring. |
| MongoDB monitoring | Custom | Atlas exporter. |
| Confluent cost exporter | Custom | Kafka cost. |

## Critical config details

### Prometheus
- **Scrape filter**: `serviceMonitorSelector.matchLabels.prometheus_ingest=true` + `podMonitorSelector.matchLabels.prometheus_ingest=true`. Anything tagged with this label is scraped; everything else is ignored. **On-prem must match this convention.**
- **Host network**: Yes — Prom uses hostNetwork on iaac-tainted nodes. Allows scrape from anywhere on the node's network.
- **Node affinity**: `iaac: 'true'` + `arch: arm64` (cloud iaac nodes). On-prem we'll just use any worker — no taint.
- **Storage**: TopoLVM-managed PVC with 5% auto-resize. On-prem: hostPath or local-path-provisioner.
- **Scrape interval**: `30s`.
- **ruleSelector**: `{}` — matches all PrometheusRules (no label filter). On-prem matches this.
- **Service alerts off**: `kubeApiServer`, `kubeControllerManager`, `coreDns`, `kubeDns`, `kubeEtcd`, `kubeProxy` all disabled. `kubelet` + `kubeScheduler` + `kubeStateMetrics` enabled.
- **Grafana sub-chart**: disabled (`grafana.enabled: false`) — Grafana is its own release.
- **Alertmanager sub-chart**: disabled (`alertmanager.enabled: false`) — **the gap on-prem will close**.

### VictoriaMetrics
- **`victoria-metrics-distributed`** chart, multi-AZ (us-east-1a, us-east-1c).
- **vmauth global write**: `http://vmauth-vmauth-global-write-vm:8427/api/v1/write` (in-cluster) / `https://victoriametrics.usxpress.io/prometheus/api/v1/write` (external).
- **vmauth global read**: `http://vmauth-vmauth-global-read-vm:8427/select/0/prometheus`.
- **Retention**: 60 days.
- **vmagent**: disabled — Prom does the scrape, then remoteWrites to vminsert via vmauth.
- **vmsingle / vmcluster** within `victoria-metrics-k8s-stack`: disabled — uses the distributed setup instead.
- **vmalert**: enabled, replicas=2, `notifier.blackhole: "true"` (no routing).
- **Datasource for vmalert**: `vmauth-global-read` (queries data in VM).

### Grafana
- **Replicas + topology spread**: across AZs.
- **EFS RWX PVC**: shared storage for dashboards / state.
- **Azure AD SSO**: enabled, auto_login on, allow_assign_grafana_admin on.
- **Unified alerting**: enabled with HA peers via `grafana-headless:9094`.
- **Routing target**: configured **in Grafana UI/DB, not IaC.** — **the gap on-prem will close.**
- **Datasources**:
  - Profiles (Pyroscope) at `pyroscope-querier.pyroscope.svc.cluster.local.:4040`
  - Athena (cost data via AWS)
  - MSSQL (Octopus DB)
  - VM (implicit via vmauth, configured separately)
- **Plugins**: athena, github, aws-datasource-provisioner.
- **SMTP**: SendGrid.
- **Image renderer**: enabled.
- **Public URL**: `grafana.usxpress.io` via `default/default-public` Istio Gateway + cert-manager LE Certificate.

### vmalert today
- `notifier.blackhole: "true"` means **all alerts go to /dev/null at the vmalert layer**.
- Either cloud relies entirely on Grafana unified alerting for routing, or the routing was set up in PD UI and the vmalert config drifted.
- **On-prem will route everything via Alertmanager → PD → FS (Phase 2 of PLAN).**

### OTel architecture
- **Aggregator** collector: receives from in-cluster pods, fans out to ClickHouse + VM
- **Events** collector: ServiceAccount with k8s events read RBAC, ships events to OTel pipeline
- **External + internal** collectors: separate ingress paths; external has cert-manager LE certs
- **Metric filter** uses `IsMatch(name, ...)` regex to drop everything except cert-manager + ESO key metrics from passing through (these are the metrics we'll mirror to PrometheusRule in Phase 3)

## Gaps cloud has not closed (= where on-prem leads)

| Gap | Detail |
|---|---|
| **G1. Alertmanager disabled** | `alertmanager.enabled: false` in Prom values. Routing happens in Grafana UI. |
| **G2. vmalert routes to blackhole** | All vmalert alerts dropped. |
| **G3. PagerDuty receivers not IaC'd** | Zero `pagerduty` references in `iaac-monitoring`. |
| **G4. Freshservice integration not IaC'd** | Zero `freshservice` references. |
| **G5. Cert expiration PrometheusRule missing** | `certmanager_certificate_expiration_timestamp_seconds` is scraped but no rule fires on it. |
| **G6. ESO sync-failure PrometheusRule missing** | `externalsecret_status_condition` is scraped but no rule fires on it. |
| **G7. AWS SM rotation overdue alert missing** | No exporter, no rule. |
| **G8. SaaS-token expiration alerts missing** | Octopus / Azure AD / GitHub PAT — no exporter, no rule. |

## What replicates 1:1 vs needs right-sizing

| Replicate as-is | Right-size for on-prem |
|---|---|
| ServiceMonitor `prometheus_ingest=true` selector convention | Replica counts (cloud is multi-AZ HA; on-prem is single-AZ dev) |
| Prom + VM chart selection | Storage class (TopoLVM → hostPath / local-path / Rook-Ceph future) |
| Grafana chart + SSO + unified alerting | EFS → on-prem PVC pattern |
| OTel collector topology | ClickHouse — point at cloud's CH over VPN; don't ship on-prem |
| cert-manager + ExternalSecret patterns | — same — |

## Top-level entry points

| Component | Cloud DNS | On-prem DNS (planned) |
|---|---|---|
| Prom UI | `prometheus.internal.usxpress.io` | `prometheus.op-dev.usxpress.io` |
| Grafana | `grafana.usxpress.io` | `grafana.op-dev.usxpress.io` |
| VM external | `victoriametrics.usxpress.io` | TBD (Phase 5) |
| Alertmanager | (none — disabled) | `alertmanager.op-dev.usxpress.io` (on-prem leads) |

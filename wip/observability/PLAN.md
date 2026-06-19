# Observability + Monitoring on-prem — PLAN

*Drafted 2026-06-02 (Tue PM). Author: Doke. Replicates cloud `iaac-monitoring` patterns where applicable; uses on-prem as the lead for the gaps that exist in cloud today (alert routing IaC, expiration alerts).*

## Goal (one sentence)

Stand up production-grade metrics + alerting + UI observability on op-usxpress-dev, wired to the corporate **PagerDuty + Freshservice** stack, mirroring cloud's chart selection where it makes sense, and IaC'ing the gaps cloud has not codified yet — so the pattern back-ports.

## Principles

1. **Same charts as cloud, right-sized for on-prem.** kube-prometheus-stack, VictoriaMetrics, Grafana, OTel — all match cloud's chart family, just with op-usxpress-dev-appropriate replica counts + storage. Avoids divergence.
2. **Reuse the 4-pattern frame** ([memory](../../../home/codespace/.claude/projects/-workspaces-eks-code/memory/cloud_to_onprem_workload_patterns_jun02.md)) for workload-level observability:
   - **Bento** carries PrometheusRule + ServiceMonitor + dashboards along with the Octopus project
   - **mirror-release.py** ships ongoing releases that carry observability artifacts
   - **cross-cluster-eso** bridges PagerDuty service keys, remote_write auth tokens, Azure AD client secrets from cloud k8s
   - **Kyverno** enforces `cluster=op-usxpress-dev` + `prometheus_ingest=true` labels at admission — no chart fork required
3. **Additive, never modify cloud.** Zero cloud impact unless explicitly back-porting after pattern validation.
4. **On-prem leads on alert routing.** Cloud's `iaac-monitoring` has zero PD/FS/Alertmanager codification. We IaC the route here, then back-port to cloud (Phase 9).
5. **Same incident stack.** PagerDuty for paging (existing `usx-pagerduty` rotation), Freshservice for tickets (Josh G. is admin). No new tools.

---

## Phase 0 — Decisions to lock *(this week, ~3 days)*

These four decisions gate Phases 1–6. Resolve before any IaC PRs.

| Decision | Options | Recommendation | Sign-off needed |
|---|---|---|---|
| **D1. Long-term metrics backend** | (A) Local VictoriaMetrics cluster on-prem; (B) Remote_write from on-prem Prom → cloud VM over VPN; (C) AWS Managed Prometheus (AMP) for both | **B for Phase 1** (zero new infra, leverages cloud's 60d retention + vmauth, single query plane). Revisit A if VPN/quota issues. | Vibin |
| **D2. Grafana strategy** | (A) Own on-prem Grafana instance; (B) Federate cloud Grafana to on-prem Prom data source over VPN | **A** — same chart as cloud (Azure AD SSO, EFS replaced with on-prem RWX or hostPath PVC). Independent UI for on-prem dashboards + alerting; supports the Bento ride-along pattern. | Vibin |
| **D3. Alert routing target** | (A) Alertmanager → PagerDuty → Freshservice; (B) Grafana unified alerting → PagerDuty → Freshservice; (C) Both | **C — both, with Alertmanager primary for Prom-rule alerts and Grafana unified for dashboard/SLO alerts.** Mirror cloud's `unified_alerting.enabled: true`, but ALSO enable Alertmanager on-prem (cloud has it off — on-prem leads). | Brendan + Steve Duck |
| **D4. Pyroscope + OTel scope** | Defer or include in Phase 1 | **Defer Pyroscope** until on-prem app has continuous profiling ask. **OTel: defer to Phase 6**, after metrics + alerts + UI are stable. | Doke unilateral |

**Acceptance**: Decisions D1–D4 written into [PLAN.md](PLAN.md) header, communicated to Vibin + Brendan, sub-tickets re-scoped accordingly.

---

## Phase 1 — On-prem Prometheus baseline standardization *(week of Jun 8)*

**Goal**: Bring on-prem Prom into structural parity with cloud (same selectors, same labels, same chart values where applicable), set `cluster` external_label, validate INFRA-1503 alerts route correctly once Phase 2 wires Alertmanager.

| Work | Repo / PR | Notes |
|---|---|---|
| Add `cluster: op-usxpress-dev` to Prom `externalLabels` | `iaac-talos-flux-platform op-dev`, `infrastructure/prometheus/values.yaml` | Single-line PR, no behavior change today; readied for federation/remote_write |
| Align ServiceMonitor selector to `prometheus_ingest=true` (cloud convention) | Same PR | Today on-prem Prom scrapes default-namespace ServiceMonitors; align with cloud's tag-filter pattern |
| Kyverno ClusterPolicy: auto-add `prometheus_ingest=true` to ServiceMonitor + PodMonitor on admission | `iaac-talos-flux-platform op-dev`, `infrastructure/kyverno-policies/` | Additive, opt-out via explicit `prometheus_ingest=false`. Means Bento'd apps automatically get scraped |
| Kyverno ClusterPolicy: auto-add `cluster=op-usxpress-dev` to all Pods + Services + Prometheus instance | Same | Cheap, allows future federation; cloud will get its mirror via back-port |
| Add `prometheus-blackbox-exporter` + `prometheus-adapter` (cloud has both) | `infrastructure/prometheus/` | Blackbox enables URL probes for ingress endpoints; adapter enables custom HPA metrics |
| Confirm scrape targets after standardization | runbook | RW, ESO, cert-manager, Cilium, Istio, Flux — full list in cloud's chart |

**Acceptance**:
- `kubectl -n prometheus get prometheus -o yaml | yq '.spec.externalLabels'` shows `cluster=op-usxpress-dev`
- `kubectl get servicemonitor -A -o json | jq '.items[] | .metadata.labels.prometheus_ingest'` returns `"true"` for ≥90% of monitors (cluster-installed-default ones may not have it yet)
- Kyverno policies VALID=True, no admission rejections
- All 12 INFRA-1503 alerts still loaded (no regression)

**Ticket**: New sub-task **INFRA-1516 — Prom baseline standardization**.

---

## Phase 2 — Alertmanager + PagerDuty + Freshservice wire *(week of Jun 15)*

**Goal**: First end-to-end alert routing from on-prem Prom → PagerDuty → Freshservice ticket. Establishes the pattern that **on-prem will use for everything**, and that cloud will eventually back-port to.

| Work | Repo / PR | Notes |
|---|---|---|
| Enable Alertmanager in on-prem Prom values | `iaac-talos-flux-platform op-dev` | Cloud has this OFF (gap); on-prem leads. Single Alertmanager replica is fine for dev. |
| Bootstrap PagerDuty services + integration keys | PagerDuty UI + Doke + Brendan | One PD service per pillar: `op-usxpress-dev-platform`, `op-usxpress-dev-rw-dataplane`, `op-usxpress-dev-ingress`, `op-usxpress-dev-secrets-identity`. Each gets an integration key. |
| ExternalSecret: PagerDuty integration keys from AWS SM | `iaac-talos-flux-platform op-dev`, `infrastructure/prometheus/` | One ExternalSecret per pillar, mounted into Alertmanager Secret. SM path: `op-usxpress-dev/pagerduty/<pillar>` |
| Alertmanager config: route tree by `severity` + `pillar` label | Same | Match INFRA-1503's labels: `severity={critical,warning}`, `pillar={platform,rw,ingress,secrets}` |
| PagerDuty → Freshservice integration | PagerDuty UI + **Josh G.** sync | Per PD docs, "Add Extension" → Freshservice. Need Josh to confirm FS service desk + category + assignment group |
| Smoke test: fire a synthetic alert, verify PD page + FS ticket | runbook | Use `amtool alert add` or kubectl trigger of a contrived rule |
| Test the 12 INFRA-1503 alerts route correctly | runbook | One-by-one; document which page which pillar |
| Codify the routing tree as IaC (yaml in repo, not PD UI) | Same | Critical — this is the gap-vs-cloud we're closing |

**Acceptance**:
- Test alert fires → PD incident opens → FS ticket opens within 60s
- All 12 INFRA-1503 alerts route to a documented pillar (no `default-fallback`)
- PD on-call rotation receives smoke-test page (validates rotation + acks)

**Blocked on**: Josh G. sync (15-min walkthrough on FS integration target)

**Ticket**: New sub-task **INFRA-1517 — Alertmanager + PD + FS wire**.

---

## Phase 3 — Expiration alert suite *(week of Jun 22)*

**Goal**: Build out the alerting class that cloud is missing entirely: **anything that can expire and silently break production** — certs, secrets, SaaS tokens, IAM tokens. This is Doke's stated focus in the Teams DM, and where on-prem leads cloud most clearly.

| Alert | Source metric | Recommendation |
|---|---|---|
| Certificate expires < 21d | `certmanager_certificate_expiration_timestamp_seconds` (cert-manager) | PrometheusRule, warning at 21d, critical at 7d |
| Certificate not Ready > 10min | `certmanager_certificate_ready_status` | PrometheusRule, critical |
| ExternalSecret sync failed > 1h | `externalsecret_status_condition{condition="Ready",status="False"}` | PrometheusRule, warning |
| ExternalSecret last sync > 24h | `externalsecret_sync_calls_total` rate | PrometheusRule, warning |
| ESO provider call failure rate | `externalsecret_provider_api_calls_count_total{status="error"}` | PrometheusRule, warning if >5% over 15min |
| AWS SM secret rotation overdue | `aws_sm_secret_last_rotated_timestamp` (custom exporter; see below) | PrometheusRule, warning at 80d, critical at 90d |
| Octopus API key expires < 30d | custom exporter (calls Octopus REST `/api/users/<id>` + `LastLoginAt`) | PrometheusRule, warning |
| Azure AD client secret expires < 30d | custom exporter via Microsoft Graph `/applications/{id}/passwordCredentials` | PrometheusRule, warning |
| GitHub PAT expires < 30d | custom exporter via GH API `/user` headers | PrometheusRule, warning |
| Flux reconcile failed > 30min | `gotk_reconcile_condition{status="False",type="Ready"}` | PrometheusRule, warning (already INFRA-1503 partial) |

**Custom exporter approach**: build one lightweight exporter `usx-expiration-exporter` that polls SM / Graph / Octopus / GitHub and emits `*_expires_in_seconds` metrics. Helm chart in `iaac-talos-flux-platform`. ESO mounts the API tokens. Kyverno enforces `prometheus_ingest=true`.

| Work | Repo / PR | Notes |
|---|---|---|
| Add `cert-expiration` + `eso-health` + `flux-extra` rule groups to INFRA-1503's PrometheusRule | `iaac-talos-flux-platform op-dev`, `infrastructure/prometheus/platform-alerts.yaml` | Extend existing file |
| Scaffold `usx-expiration-exporter` repo | NEW repo: `variant-inc/usx-expiration-exporter` | Go service, 4 collectors (SM, Octopus, Azure AD, GitHub). Helm chart in same repo. |
| Deploy exporter | `iaac-talos-flux-platform op-dev`, `infrastructure/usx-expiration-exporter/` | One HelmRelease, secrets from cloud SM via ExternalSecret |
| Add expiration rule group | Same | Wired to PD `op-usxpress-dev-secrets-identity` service |

**Acceptance**:
- Force-rotate a test SM secret with a near-expiry date → alert fires within 15min
- Cert expiration alert fires when a Certificate is patched with a 7d validity
- ESO Ready=False flips → alert fires within 5min

**Ticket**: New sub-task **INFRA-1519 — Expiration alert suite + custom exporter**.

---

## Phase 4 — Grafana on-prem *(week of Jun 29 — 2 weeks)*

**Goal**: UI for dashboards + alerts + SLOs. Same chart + same SSO as cloud. Public URL via existing `shared-http` Gateway.

| Work | Repo / PR | Notes |
|---|---|---|
| Add `grafana` Flux Kustomization | `iaac-talos-flux-cluster master`, `clusters/bm-dev/flux-system/infra.yaml` | Standard `dependsOn: prometheus` |
| HelmRelease + ConfigMap of values (mirroring cloud's `grafana/values.yaml.gotmpl`) | `iaac-talos-flux-platform op-dev`, `infrastructure/grafana/` | Strip multi-AZ / EFS / Athena. Keep Azure AD SSO + Prom DS + Grafana unified alerting |
| Azure AD app reg for on-prem Grafana | Vibin + IT | New app or reuse cloud's with extra reply URL? Decision in Phase 0 |
| Persistence: hostPath PVC on iaac-labelled worker (Talos pattern) | Same | EFS doesn't apply on-prem; use single PVC bound to a fixed worker (acceptable for dev) |
| ExternalSecret: Azure AD client secret, admin password | Same | From cloud SM via cross-cluster-eso pattern |
| Certificate for `grafana.op-dev.usxpress.io` | cert-manager Cert resource in `istio-ingress` ns | LE prod via existing wildcard chain |
| VirtualService on `shared-http` Gateway | `infrastructure/grafana/virtualservice.yaml` | Routes `grafana.op-dev.usxpress.io` → grafana svc :80 |
| Default datasources: local Prom, future VM | Same | Mirror cloud's datasource list (minus Athena + MSSQL) |
| Default dashboards: import cloud's k8s + istio + cert-manager dashboards | Grafana ConfigMap (provisioning) | Use Grafana sidecar; consume from a label-selected ConfigMap |
| Grafana unified alerting → PagerDuty contact point | Grafana provisioning YAML | Mirrors Phase 2 routing; allows dashboard-defined alerts to page |

**Acceptance**:
- `https://grafana.op-dev.usxpress.io` returns Azure AD login → user-friendly dashboard
- Datasource "Prometheus (op-usxpress-dev)" is healthy
- One imported dashboard renders (e.g. "Kubernetes / Cluster")
- A test alert in Grafana fires → PD page + FS ticket

**Ticket**: New sub-task **INFRA-1520 — Grafana on-prem**.

---

## Phase 5 — Long-term storage implementation *(week of Jul 13 — 2 weeks)*

**Per Phase 0 decision D1.** Plan below assumes recommendation (B): remote_write from on-prem Prom → cloud VM.

| Work | Repo / PR | Notes |
|---|---|---|
| Add cloud VM SA + Role + RoleBinding + Token (cross-cluster-eso pattern) for remote_write auth | `iaac-monitoring` (cloud-side PR — needs Vibin) | Read-only SA in `victoriametrics` ns, token via secret bridge |
| On-prem ExternalSecret pulls the token | `iaac-talos-flux-platform op-dev`, `infrastructure/prometheus/` | Standard ESO ClusterSecretStore=cloud k8s pattern (see [cross-cluster-eso](../../../home/codespace/.claude/projects/-workspaces-eks-code/memory/cloud_to_onprem_workload_patterns_jun02.md)) |
| Add `remoteWrite` block to Prom values pointing at cloud `vmauth-vmauth-global-write-vm:8427/prometheus/api/v1/write` over VPN | Same | `bearerToken` from the ESO-pulled Secret; `cluster=op-usxpress-dev` external_label means cloud queries can filter by cluster |
| Validate ingestion in cloud VM | runbook | `curl vmauth-read 'query={cluster="op-usxpress-dev"}'` returns series |
| Optional rollback: local 7d retention stays on; remote_write is additive | — | Default: keep local Prom retention at 7d; remote_write feeds long-term to VM |

**Acceptance**:
- Cloud Grafana query `{cluster="op-usxpress-dev"}` returns data via cloud VM
- On-prem Grafana query against cloud VM datasource returns data
- Network drop test: remote_write buffers + recovers (Prom buffers ~2h by default)

**Alternate path if D1=A (local VM cluster)**: replicate `victoriametrics` Helm setup right-sized for 7 workers (1 vminsert + 1 vmselect + 1 vmstorage replica). ~50% more work; choose only if Vibin rejects federation.

**Ticket**: New sub-task **INFRA-1521 — Long-term metrics storage**.

---

## Phase 6 — OTel traces parity *(deferred to Aug, ~2 weeks when picked up)*

**Trigger**: First on-prem workload that needs traces (likely from Bento'd cloud app — brands/attrition/io-notifications).

| Work | Repo / PR | Notes |
|---|---|---|
| Mirror cloud OTel aggregator + events collectors | `iaac-talos-flux-platform op-dev`, `infrastructure/otel/` | Replicate `iaac-monitoring/charts/templates/otel-extras/` |
| Cert for OTel ingress | cert-manager | Reuse wildcard chain |
| Traces to cloud ClickHouse (no on-prem CH) | Same | OTel exporter points at `clickhouse.dpl.usxpress.io:9000` over VPN |
| Metrics to cloud VM (already wired in Phase 5) | Same | OTel writes metrics via same remote_write |
| ServiceMonitor for OTel-collector self-metrics | Same | Standard k-p-stack pattern |

**Acceptance**: One on-prem pod with OTel instrumentation produces traces visible in cloud Grafana via ClickHouse DS.

**Ticket**: New sub-task **INFRA-1522 — OTel traces parity** (defer-tagged).

---

## Phase 7 — Pyroscope *(deferred indefinitely)*

Hold until an on-prem workload requests continuous profiling. Federation to cloud Pyroscope likely cleaner than ship-on-prem.

---

## Phase 8 — Workload portability ride-along *(cross-cutting, ongoing)*

**Goal**: Every cloud workload Bento'd into on-prem brings its observability artifacts with it. No re-authoring.

| Acceptance checklist (added to on-prem app-onboarding template) | |
|---|---|
| App's Octopus project includes `PrometheusRule` | ✅ required |
| App's Octopus project includes `ServiceMonitor` (or relies on the Kyverno auto-label from Phase 1) | ✅ required |
| App's Octopus project includes Grafana dashboard JSON (as ConfigMap with `grafana_dashboard=1` label) | ✅ required |
| App's alerts include `pillar=<team>` label for PD routing | ✅ required |

**Validation app**: first Bento'd cloud workload (brands/attrition/io-notifications) runs through this checklist end-to-end.

**Ticket**: New story **INFRA-1523 — On-prem app-onboarding observability checklist**.

---

## Phase 9 — Back-port to cloud *(after on-prem patterns proven, ~Aug–Sep)*

**Goal**: Close the gaps the on-prem build-out surfaced in cloud `iaac-monitoring`.

| Gap | Back-port |
|---|---|
| Alertmanager off in cloud | Enable + codify routing tree |
| PagerDuty receivers not IaC'd | Add Alertmanager `pagerduty_configs` to cloud values |
| Grafana unified alerting routing in UI not Git | Add Grafana provisioning YAML to repo |
| vmalert `notifier.blackhole: "true"` | Wire to Alertmanager or PD directly |
| No certificate expiration rules | Lift INFRA-1519 PrometheusRule onto cloud cluster (chart values, same file) |
| No ESO sync-failure rules | Same |
| No SaaS-token expiration exporter | Deploy `usx-expiration-exporter` on cloud cluster |

**Ticket**: New Story **INFRA-1524 — Cloud monitoring gap back-port**.

---

## Tickets to file

Under existing initiative **INFRA-472** (on-prem cluster platform), peer to **INFRA-1499** (ingress umbrella) and **INFRA-1513** (Wiz):

| ID (proposed) | Type | Title | Phase |
|---|---|---|---|
| INFRA-1514 | Epic | Unified hybrid observability for op-usxpress-dev | — (umbrella) |
| INFRA-1515 | Sub-task | Phase 0 decisions: backend + routing target + Grafana strategy | 0 |
| INFRA-1516 | Sub-task | Phase 1: Prom baseline standardization (externalLabels + selectors + Kyverno) | 1 |
| INFRA-1517 | Sub-task | Phase 2: Alertmanager + PagerDuty + Freshservice routing | 2 |
| INFRA-1518 | Sub-task | Phase 2 follow-up: PD→FS integration sync with Josh G. | 2 |
| INFRA-1519 | Sub-task | Phase 3: Expiration alert suite + `usx-expiration-exporter` | 3 |
| INFRA-1520 | Sub-task | Phase 4: Grafana on-prem (chart + SSO + VS + dashboards) | 4 |
| INFRA-1521 | Sub-task | Phase 5: Long-term metrics storage (per D1) | 5 |
| INFRA-1522 | Sub-task | Phase 6: OTel traces parity (deferred) | 6 |
| INFRA-1523 | Story | On-prem app-onboarding observability checklist | 8 |
| INFRA-1524 | Story | Cloud monitoring gap back-port | 9 |

---

## Risks + mitigations

| Risk | Mitigation |
|---|---|
| Azure AD app reg for Grafana SSO takes weeks of IT cycles | Start the request in Phase 0; bridge with admin password until SSO lands |
| Cloud VM remote_write capacity / write quota | Validate with Vibin in Phase 0; fall back to local VM if rejected |
| Custom expiration exporter complexity creep | Lock to 4 collectors max (SM, Octopus, Azure AD, GitHub); resist scope add |
| PD service explosion (one per app) | Limit to 4 pillars in Phase 2; per-app alerts route to pillar by label, not service |
| Bento ride-along not enforced — workloads land without rules | Phase 8 checklist becomes acceptance criterion in PR template + Vibin sign-off |
| On-prem Alertmanager + Grafana unified both pageable → duplicate pages | Use dedup_key on PD side; or restrict Grafana unified to dashboard-derived alerts only |
| Cloud back-port stalls because cloud team is busy | On-prem track is independent; back-port can wait without blocking on-prem ops |

---

## How this composes with prior work

- **Wiz (INFRA-1513)** runs in parallel. Wiz = security observability (CVE, runtime, posture). This Epic = operational observability (health, latency, expiration). No tool overlap; alert routing converges at PD pillars (Pillar 3 secrets/identity is shared).
- **Phase 1 Cilium NetworkPolicy** (already shipped): scrape from on-prem Prom to workload metrics endpoints needs explicit CNP allow if we add CNPs to other namespaces. Track in Phase 1 acceptance.
- **MeshConfig exportTo fix** (already shipped): Grafana on `grafana.op-dev.usxpress.io` will work because of this — without it, the gateway can't reach the grafana Service. Documented as a hidden dependency.
- **cert-manager + wildcard chain** (Phase 0 networking complete): provides the cert for `grafana.op-dev.usxpress.io` without any new IRSA work.

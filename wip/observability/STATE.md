# Observability + Monitoring on-prem — STATE

*Initiative kicked off 2026-06-02 (Tue PM).*

**Headline:** Networking + RW data plane are done. Wiz program is filed (security observability). Now: build the metrics/alerts/UI observability story for op-usxpress-dev, replicate the cloud stack where it makes sense, codify the cloud's own gaps (alert routing, expiration alerts, ESO-failure alerts), and wire it to the corporate **PagerDuty + Freshservice** stack confirmed by Steve Duck 2026-06-02.

**Reference architecture (cloud, in `iaac-monitoring`):**
- **kube-prometheus-stack** as scraper (Alertmanager OFF, defaultRules OFF, scrapes things tagged `prometheus_ingest=true`)
- **VictoriaMetrics distributed** as long-term storage + query backend (60-day retention, vmauth gateway)
- **vmalert** as rule engine querying VM (currently `notifier.blackhole: "true"` — alerts dropped)
- **Grafana** as UI (Azure AD SSO, unified alerting on, routing-to-PD configured in UI, not IaC)
- **Pyroscope** for continuous profiling, **OTel** for traces, **ClickHouse** for trace storage
- **kubecost**, **MongoDB monitoring**, **Confluent cost exporter** for adjuncts

**On-prem today (op-usxpress-dev):**
- kube-prometheus-stack v3.4.1 in `prometheus` ns (standalone Flux HelmRelease, NOT through fluxcd-release ECR pattern)
- 12 platform-health alerts (`PrometheusRule platform-health`, INFRA-1503) — **unrouted today**
- No VictoriaMetrics, no Grafana, no Pyroscope, no OTel
- No alert routing to PD/FS
- No expiration-alert suite

**Stack confirmed for routing:**
- **Freshservice** = official ITSM (Steve Duck 2026-06-02; Josh G. is admin)
- **PagerDuty** = paging (corporate `usx-pagerduty`)
- No ServiceNow

**Gaps in cloud we will codify on-prem first** (per Doke's Teams DM to Steve 2026-06-02):
1. Alert routing not IaC'd (lives in Grafana UI / DB)
2. No certificate expiration alerts visible in IaC
3. No ExternalSecret sync-failure alerts
4. No AWS SM rotation-overdue alerts
5. No SaaS-token expiration alerts (Octopus API key, Azure AD client secret, GH PAT, etc.)

## Read order

1. [PLAN.md](PLAN.md) — 9-phase plan + acceptance criteria + tickets to file
2. [CLOUD-REFERENCE.md](CLOUD-REFERENCE.md) — what cloud's `iaac-monitoring` actually does (replication source)
3. [phase1-draft/](phase1-draft/) — ready-to-PR drafts for INFRA-1516 (Prom baseline standardization)
4. [memory `cloud_to_onprem_workload_patterns_jun02`](../../../home/codespace/.claude/projects/-workspaces-eks-code/memory/cloud_to_onprem_workload_patterns_jun02.md) — the 4-pattern frame (Bento, mirror-release, cross-cluster-eso, Kyverno)
5. [memory `reference_usx_incident_stack`](../../../home/codespace/.claude/projects/-workspaces-eks-code/memory/reference_usx_incident_stack.md) — FS + PD confirmation

## Status

- [x] Cloud stack inspected (`iaac-monitoring` repo)
- [x] Incident-tool stack confirmed (Steve 2026-06-02)
- [x] Plan drafted (this file + PLAN.md, 2026-06-02 PM)
- [x] **Epic + 10 Stories filed under INFRA-472** (2026-06-02 PM)
- [x] **Phase 1 PR drafts staged** in [phase1-draft/](phase1-draft/) (helmrelease diff + 2 Kyverno ClusterPolicies + backfill script + selector-flip diff)
- [ ] Phase 0 decisions locked (backend, routing target, Grafana strategy)
- [ ] Phase 1 PRs pushed from WSL2 (4 PRs in sequence per `phase1-draft/README.md`)

## Filed tickets

| Ticket | Phase | Title |
|---|---|---|
| [INFRA-1514](https://usxpress.atlassian.net/browse/INFRA-1514) | Epic | Unified hybrid observability for op-usxpress-dev |
| [INFRA-1515](https://usxpress.atlassian.net/browse/INFRA-1515) | 0 | Lock decisions (backend / Grafana / routing / OTel scope) |
| [INFRA-1516](https://usxpress.atlassian.net/browse/INFRA-1516) | 1 | Prom baseline standardization |
| [INFRA-1517](https://usxpress.atlassian.net/browse/INFRA-1517) | 2 | Alertmanager + PD + FS routing wire |
| [INFRA-1518](https://usxpress.atlassian.net/browse/INFRA-1518) | 2 | PD → FS integration sync with Josh G. |
| [INFRA-1519](https://usxpress.atlassian.net/browse/INFRA-1519) | 3 | Expiration alert suite + `usx-expiration-exporter` |
| [INFRA-1520](https://usxpress.atlassian.net/browse/INFRA-1520) | 4 | Grafana on-prem |
| [INFRA-1521](https://usxpress.atlassian.net/browse/INFRA-1521) | 5 | Long-term metrics storage |
| [INFRA-1522](https://usxpress.atlassian.net/browse/INFRA-1522) | 6 | OTel traces parity (deferred) |
| [INFRA-1523](https://usxpress.atlassian.net/browse/INFRA-1523) | 8 | App-onboarding observability checklist |
| [INFRA-1524](https://usxpress.atlassian.net/browse/INFRA-1524) | 9 | Cloud monitoring gap back-port |

## Owners

- **Doke** — initiative lead, on-prem build-out
- **Josh G.** — Freshservice admin (PD → FS integration)
- **Steve Duck** — networking egress + routing decisions
- **Matt Hagden (Director)** — cloud-side decisions previously routed to Vibin (D1 backend choice, D2 Grafana strategy, D4 OTel/Pyroscope scope) until cloud lead backfill lands. See [vibin_departure_jun03](../../../home/codespace/.claude/projects/-workspaces-eks-code/memory/vibin_departure_jun03.md).
- **Brendan Buschel** — on-call routing tree (CySec rotation overlap)

## Related initiatives

- [`wip/wiz-onprem-onboarding-repo/`](../wiz-onprem-onboarding-repo/) — security observability (parallel track)
- [`wip/onprem-networking/`](../onprem-networking/) — completed, unblocks Grafana ingress here

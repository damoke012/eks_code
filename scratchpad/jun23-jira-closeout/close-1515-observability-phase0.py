#!/usr/bin/env python3
"""Lock the 4 Phase 0 decisions on INFRA-1515 and transition to Done.

Decisions to lock:
1. Backend = kube-prometheus-stack (deployed, operational on ceph-block)
2. Grafana strategy = Helm chart + sidecar dashboards + sidecar datasources + Azure AD SSO
3. Routing = pattern locked (Alertmanager -> PagerDuty -> Freshservice), wiring deferred to Phase 2 (INFRA-1517)
4. OTel scope = OUT OF SCOPE for op-usxpress-dev Phase 0-3 (mirrors cloud which doesn't run OTel collector today)
"""
import json, os, urllib.request, urllib.error, base64
from pathlib import Path

EMAIL = "doke@usxpress.com"
TOKEN = ""
for ln in Path("/workspaces/eks_code/scripts/push-to-confluence.sh").read_text().splitlines():
    if ln.startswith("CONFLUENCE_TOKEN="):
        TOKEN = ln.split("=", 1)[1].strip().strip('"').strip("'")
        break
assert TOKEN, "token not found in scripts/push-to-confluence.sh"
BASE = "https://usxpress.atlassian.net"
auth = base64.b64encode(f"{EMAIL}:{TOKEN}".encode()).decode()
HEADERS = {"Authorization": f"Basic {auth}", "Accept": "application/json", "Content-Type": "application/json"}


def adf(text):
    blocks = []
    for para in text.strip().split("\n\n"):
        lines = para.split("\n")
        if all(l.startswith("- ") for l in lines):
            items = [{"type": "listItem", "content": [{"type": "paragraph", "content": [{"type": "text", "text": l[2:]}]}]} for l in lines]
            blocks.append({"type": "bulletList", "content": items})
        else:
            content = []
            for i, l in enumerate(lines):
                if i > 0:
                    content.append({"type": "hardBreak"})
                if l:
                    content.append({"type": "text", "text": l})
            blocks.append({"type": "paragraph", "content": content})
    return {"type": "doc", "version": 1, "content": blocks}


def api(method, path, body=None):
    req = urllib.request.Request(
        f"{BASE}{path}",
        data=json.dumps(body).encode() if body else None,
        method=method,
        headers=HEADERS,
    )
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        print(f"  HTTP {e.code}: {e.read().decode()[:500]}")
        raise


def comment(key, text):
    res = api("POST", f"/rest/api/3/issue/{key}/comment", {"body": adf(text)})
    print(f"  {key} commented (id {res.get('id')})")


def transitions(key):
    res = api("GET", f"/rest/api/3/issue/{key}/transitions")
    return {t["name"]: t["id"] for t in res.get("transitions", [])}


def transition(key, name):
    avail = transitions(key)
    if name not in avail:
        print(f"  {key} can't go to '{name}' — available: {list(avail.keys())}")
        return False
    api("POST", f"/rest/api/3/issue/{key}/transitions", {"transition": {"id": avail[name]}})
    print(f"  {key} -> {name}")
    return True


# ---- Phase 0 decisions comment ----

comment("INFRA-1515", """2026-06-24 — Phase 0 decisions LOCKED. All 4 dimensions resolved; closing.

Decision 1 — METRICS BACKEND: kube-prometheus-stack
- Chart: prometheus-community/kube-prometheus-stack v72.9.1 (app v3.4.1)
- Components shipped: Prometheus Operator + Prometheus server + Alertmanager + prometheus-node-exporter + kube-state-metrics + Operator CRDs
- Storage: ceph-block, 20Gi PVC, 4Gi memory limit (was 1Gi -- OOMKilled during WAL replay + ServiceMonitor scrape pool init; bumped via PR #69)
- ServiceMonitor discovery: serviceMonitorSelectorNilUsesHelmValues=false (auto-pick up SMs from every namespace; matches cloud iaac-monitoring behavior)
- node-exporter: hostNetwork=false (PR #66) -- mixed-chart envs have hostPort 9100 collisions with legacy prometheus@29.x in risingwave-2/monitoring namespaces; will revert to hostNetwork=true once legacy charts are retired
- CP-safety: nodeAffinity DoesNotExist on node-role.kubernetes.io/control-plane; tolerations=[] (Rule 1 of /onprem-safety)
- Namespace: prometheus (PSA enforce=privileged via PR #65 to admit node-exporter hostPath mounts)
- Repo: variant-inc/iaac-talos-flux-platform op-dev/infrastructure/prometheus

Decision 2 — GRAFANA STRATEGY: Helm chart + sidecar pattern
- Chart: grafana/grafana v11.4.0
- Dashboard provisioning: sidecar discovers ConfigMaps with label grafana_dashboard=1 (org-wide via SEARCH_NAMESPACE=ALL)
- Folder organization: Kyverno ClusterPolicy auto-labels grafana_folder from CM namespace -- "monitoring/grafana-foo" lands in "monitoring" folder
- Datasource provisioning: sidecar discovers CMs with label grafana_datasource=1 + values.yaml-shipped Prometheus DS (uid=prometheus pinned -- PR #67); deleteDatasources block bypasses editable=false on UID reprovision (PR #68)
- Storage: ceph-block, 10Gi PVC; chart-doesn't-auto-restore-deleted-PVCs gotcha noted -- new PVC requires Helm adoption labels on manual apply
- SSO: Azure AD OIDC (USXPress tenant bbb5a66d-5c9f-482a-969a-a40304b6bc8d) -- config skeleton shipped with enabled=false; live login waits on INFRA-1558 (Application Administrator must register OAuth app)
- Ingress: grafana.op-dev.usxpress.io via Istio Gateway + cert-manager wildcard cert (uses [[onprem-per-team-cert-pattern]])
- Admin creds: op-usxpress-dev/platform/grafana SM
- Repo: variant-inc/iaac-talos-flux-platform op-dev/infrastructure/grafana

Decision 3 — ALERT ROUTING: pattern locked, wiring deferred to Phase 2 (INFRA-1517)
- Pipeline: Prometheus -> Alertmanager (chart-bundled) -> PagerDuty webhook receiver -> PagerDuty service -> Freshservice ticket via PD-FS integration
- Mirrors cloud iaac-monitoring topology
- Severity routing rules + on-call schedules will be ported from cloud Alertmanager config
- Status: NOT wired -- per directive tonight ("deprioritize alert routing for now"). Empty default receiver until Phase 2.
- Sub-task INFRA-1517 carries the wiring work; this ticket only locks the pattern decision.

Decision 4 — OTel SCOPE: OUT OF SCOPE for op-usxpress-dev Phase 0-3
- Rationale: cloud iaac-monitoring does NOT run an OpenTelemetry collector today; on-prem mirror inherits that decision. We do not want to introduce a divergence the cloud team hasn't validated.
- Workloads that need distributed tracing: route directly to cloud Honeycomb/Datadog endpoints via cross-cluster egress -- same path as today.
- Revisit trigger: when cloud iaac-monitoring adds an OTel collector, on-prem will follow within one sprint. Not before.
- This decision INTENTIONALLY scopes Phase 0-3 to Prometheus + Grafana + Alertmanager. Logs/traces stay on the cloud side until the cloud canonical pattern includes them.

Phase 0 acceptance criteria — all met:
- [x] Metrics backend chosen + deployed + storage class + memory limits locked
- [x] Grafana strategy chosen + dashboard pattern + datasource pattern + SSO skeleton
- [x] Routing pattern locked (wiring is a Phase 2 ticket, not a Phase 0 blocker)
- [x] OTel scope explicitly decided (out of scope, revisit trigger documented)

Downstream tickets unblocked:
- INFRA-1516 — node-exporter & KSM (already shipped via PR #64, will be marked done in this sweep)
- INFRA-1517 — Alertmanager wiring + PD routing (Phase 2)
- INFRA-1518 — additional dashboards beyond the baseline
- INFRA-1519 — PrometheusRule library + SLO rules
- INFRA-1520 — Grafana (DONE 2026-06-23)
- INFRA-1521-1524 — successive phases (see [Observability plan jun02])

Closing this ticket. Phase 0 = done.""")

if not transition("INFRA-1515", "Done"):
    # try other common done states
    for n in ("Closed", "Resolved", "Complete"):
        if transition("INFRA-1515", n):
            break

print("Done.")

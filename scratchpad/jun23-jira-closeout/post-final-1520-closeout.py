#!/usr/bin/env python3
"""Final INFRA-1520 closeout comment with the full PR chain + capture lessons.

Also adds a memory-worthy follow-up sub-ticket for the kube-prometheus-stack
PVC PSA + datasource UID gotchas.
"""
import json, os, urllib.request, base64

EMAIL = os.environ['ATLASSIAN_EMAIL']
TOKEN = os.environ['ATLASSIAN_TOKEN']
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
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read().decode() or "{}")


def comment(key, text):
    res = api("POST", f"/rest/api/3/issue/{key}/comment", {"body": adf(text)})
    print(f"  {key} commented (id {res.get('id')})")


comment("INFRA-1520", """2026-06-24 03:30 UTC — FULL CLOSEOUT (browser verified).

Dashboard "Kubernetes Cluster Overview (op-usxpress-dev)" now renders REAL data:
- Nodes: 10
- Pods (total): 214
- Cluster CPU (used %): 79.4%
- Cluster Memory (used %): 29.3%
- CPU + Memory per node: all 7 worker IPs charting
- Pods per namespace: stacked timeseries

PR chain that got us here (6 PRs against variant-inc/iaac-talos-flux-platform):

- PR #63 — feat(grafana) Phase 4 IaC: ceph-block migration + Azure AD SSO skeleton + baseline dashboard CM + ExternalSecret
- PR #64 — fix(prometheus): enable node-exporter (CP-safe) + values nudge to force chart re-apply (kube-prometheus-stack chart's resources had been destroyed during marathon PR #56 PVC migration; chart remained "deployed" in Helm storage but namespace was empty)
- PR #65 — fix(prometheus): label ns PSA privileged so node-exporter pods get admitted (default cluster PSA enforce is baseline; node-exporter needs hostNetwork/hostPID/hostPath which baseline rejects)
- PR #66 — fix(prometheus): node-exporter hostNetwork: false (avoid hostPort 9100 collision with the legacy standalone prometheus chart's node-exporter in risingwave-2/monitoring namespaces — all workers already had 9100 bound)
- PR #67 — fix(grafana): pin Prometheus datasource uid=prometheus (chart auto-generated PBFA97CFB590B2093; dashboard references resolved to nothing)
- PR #68 — fix(grafana): deleteDatasources Prometheus (editable: false blocks API delete; provisioning's deleteDatasources runs before datasources and bypasses the read-only block)

Plus 2 manual cluster-side ops (no IaC):
- Recreated Grafana PVC on ceph-block with Helm adoption labels after the PVC migration (Helm doesn't auto-recreate user-deleted PVCs)
- Forced kube-prometheus-stack reinstall: flux suspend -> helm uninstall -> flux resume -> let chart re-install fresh

Acceptance criteria status (per the original ticket):
- [x] https://grafana.op-dev.usxpress.io returns login page (admin credentials in op-usxpress-dev/platform/grafana SM)
- [x] Datasource Prometheus healthy (uid=prometheus, url http://prometheus-stack-kube-prom-prometheus.prometheus.svc.cluster.local:9090)
- [x] One imported dashboard renders (Kubernetes Cluster Overview — all 7 panels live)
- DEFERRED: Test alert from Grafana to PD page + FS ticket — Phase 2 (INFRA-1517)
- DEFERRED: Azure AD SSO live login — INFRA-1558 (admin needs to register OAuth app)

Gotchas captured for catalog follow-up (will become catalog entries in iaac-talos/deploy/docs/troubleshooting/):
- node-exporter on Talos needs hostNetwork: false when there's another node-exporter on the same hostPort (rare in greenfield, common in mixed-stack setups like ours)
- kube-prometheus-stack chart's resources can vanish post-Velero restore exercise (test-restore-jun24 contaminated the prometheus ns); helm shows "deployed" but namespace is empty — fix is flux suspend + helm uninstall + flux resume
- Grafana auto-generated UID PBFA97CFB590B2093 silently breaks dashboard references; pin uid: prometheus + use deleteDatasources to force reprovision when changing UID (editable: false blocks API delete)
- PVC migration via storageClassName change requires manual PVC delete + Helm adoption labels on a hand-applied replacement (Helm doesn't auto-restore user-deleted PVCs)

Ticket stays Done. Marathon umbrella INFRA-1544 epic has Phase 4 now genuinely complete.""")

print("Done.")

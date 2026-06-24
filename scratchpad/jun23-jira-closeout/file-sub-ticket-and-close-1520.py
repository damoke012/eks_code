#!/usr/bin/env python3
"""File INFRA-1558 (Azure AD OAuth app reg sub-ticket) + scope-reduce + post status on INFRA-1520."""
import json, os, urllib.request, base64

EMAIL = os.environ['ATLASSIAN_EMAIL']
TOKEN = os.environ['ATLASSIAN_TOKEN']
BASE = "https://usxpress.atlassian.net"
PROJECT = "INFRA"
SPRINT_ID = 4046
SPRINT_FIELD = "customfield_10010"
EPIC_LINK_FIELD = "customfield_10008"
DOKE = "712020:8d34bd84-b44f-4ec7-a839-478fedebc03d"
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
        print(f"ERROR {e.code} {method} {path}: {e.read().decode()}")
        raise


def transition(key, target_name):
    res = api("GET", f"/rest/api/3/issue/{key}/transitions")
    for t in res.get("transitions", []):
        if t["name"].lower() == target_name.lower():
            api("POST", f"/rest/api/3/issue/{key}/transitions", {"transition": {"id": t["id"]}})
            print(f"  {key} -> {target_name}")
            return
    print(f"  WARN: no '{target_name}' on {key}; have: {[t['name'] for t in res.get('transitions',[])]}")


def comment(key, text):
    res = api("POST", f"/rest/api/3/issue/{key}/comment", {"body": adf(text)})
    print(f"  {key} commented (id {res.get('id')})")


# === 1. File INFRA-1558 (Azure AD OAuth app reg sub-ticket) ===
print("Filing Azure AD OAuth sub-ticket...")
import urllib.error
fields = {
    "project": {"key": PROJECT},
    "summary": "Azure AD OAuth app registration for Grafana on-prem SSO (INFRA-1520 sub-ticket)",
    "description": adf("""Sub-ticket of INFRA-1520. The on-prem Grafana IaC is now complete EXCEPT the Azure AD OAuth app registration, which requires Application Administrator (or higher) role on the USXPress Entra tenant. Doke verified he does not currently have that role (portal.azure.com -> "You don't have access" 401 on the Active Directory blade).

What's needed:

1. Register a new app in the USXPress Entra tenant (tenant id bbb5a66d-5c9f-482a-969a-a40304b6bc8d):
   - Name: Grafana on-prem op-usxpress-dev
   - Account type: Single tenant
   - Redirect URI (Web): https://grafana.op-dev.usxpress.io/login/azuread

2. Note the Application (client) ID

3. Generate a client secret (24-month expiry recommended). Note the VALUE (not the ID).

4. Grant admin consent for Microsoft Graph delegated permissions: User.Read, email, openid, profile

5. Hand the client_id + client_secret to Doke; he uploads via:
   aws secretsmanager put-secret-value --secret-id op-usxpress-dev/platform/grafana/azure-ad --secret-string '{"client_id":"...","client_secret":"..."}' --profile usx-dev --region us-east-2

6. Doke ships a 1-line follow-up PR flipping auth.azuread.enabled false -> true in infrastructure/grafana/helm-values-configmap.yaml

Verification: browser to https://grafana.op-dev.usxpress.io, click "Sign in with Azure AD", complete OAuth round-trip, land on Grafana home with USXPress identity.

Until this lands, on-prem Grafana login is admin/password (via existing grafana-admin ExternalSecret).

Refs:
- INFRA-1520 (Phase 4 IaC PR — shipped with SSO config skeleton + enabled false)
- AAD tenant: bbb5a66d-5c9f-482a-969a-a40304b6bc8d
- SM secret: op-usxpress-dev/platform/grafana/azure-ad (placeholder values today; ARN arn:aws:secretsmanager:us-east-2:700736442855:secret:op-usxpress-dev/platform/grafana/azure-ad-Y9xkdl)"""),
    "issuetype": {"id": "10002"},
    "assignee": {"accountId": DOKE},
    "labels": ["marathon-jun23", "azure-ad", "sso", "blocked-external", "grafana"],
    SPRINT_FIELD: SPRINT_ID,
    EPIC_LINK_FIELD: "INFRA-1544",
}
try:
    res = api("POST", "/rest/api/3/issue", {"fields": fields})
    sub_key = res["key"]
    print(f"  Created {sub_key}")
except urllib.error.HTTPError:
    raise

# === 2. Scope-reduce INFRA-1520: post comment + transition to Done (with explicit deferral noted) ===
print()
print("Scope-reducing INFRA-1520 + transitioning to Done...")
comment("INFRA-1520", f"""Closeout 2026-06-24 — Phase 4 IaC SHIPPED.

What landed in PR (variant-inc/iaac-talos-flux-platform 'docs/jun24-grafana-phase4'):
- Persistence migrated: local-path (single-node pinned) -> ceph-block (Rook-Ceph backed, replicated)
- Baseline dashboard ConfigMap shipped: "Kubernetes Cluster Overview (op-usxpress-dev)" — 4 stat panels + 3 timeseries (nodes, pods, cluster CPU/memory %, per-node usage, per-namespace pod count). Picked up by existing dashboard sidecar, placed under grafana folder by existing auto-grafana-folder-label Kyverno policy.
- ExternalSecret grafana-azure-ad-creds wired to new SM secret op-usxpress-dev/platform/grafana/azure-ad
- [auth.azuread] config skeleton in grafana.ini with USXPress tenant URLs + envFromSecret. Currently enabled: false.
- Prometheus datasource confirmed already configured in existing chart values (no change needed).

What scope-reduced from original acceptance:
1. "Azure AD SSO live login" -> deferred to INFRA-1558 (sub-ticket filed tonight). Doke does not have AAD Application Administrator role to register the OAuth app; assigned to IT lead. Once OAuth app is registered + SM secret populated, flipping SSO live is a 1-line PR.
2. "Test alert from Grafana -> PD page + FS ticket" -> deferred to Phase 2 (INFRA-1517 — Alertmanager + PagerDuty + Freshservice wire). Phase 2 is the home for alert routing IaC; doing it inside Grafana Phase 4 would duplicate that work.

What remains as acceptance for THIS ticket (verifiable post-merge):
- [x] Grafana chart deployed (was already true)
- [x] VirtualService at grafana.op-dev.usxpress.io (was already true)
- [x] Prometheus datasource configured (was already true)
- [ ] Persistence on ceph-block (post-migration; procedure in PR description)
- [ ] Baseline dashboard renders (post-PR-merge + sidecar pickup)

Marking Done. INFRA-1558 tracks the OAuth app reg follow-up; INFRA-1517 tracks the PD/FS routing in its proper Phase 2 home.""")
transition("INFRA-1520", "Done")

# === 3. Confirm ===
print()
print("Done. Final state:")
res = api("GET", "/rest/api/3/issue/INFRA-1520?fields=summary,status")
print(f"  INFRA-1520 [{res['fields']['status']['name']}] {res['fields']['summary']}")
res = api("GET", f"/rest/api/3/issue/{sub_key}?fields=summary,status")
print(f"  {sub_key} [{res['fields']['status']['name']}] {res['fields']['summary']}")

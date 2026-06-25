#!/usr/bin/env python3
"""Close INFRA-1558 once IT provisions the OAuth app + SSO live login is verified.
Edit the EVIDENCE block, then run."""
import json, urllib.request, base64
from pathlib import Path

# ============ EDIT-ME ============
CLIENT_ID = ""                       # e.g. "11111111-2222-3333-4444-555555555555"
SECRET_SM_ARN = "arn:aws:secretsmanager:us-east-2:700736442855:secret:op-usxpress-dev/platform/grafana/azure-ad-XXXXXX"
GRAFANA_PR = ""                      # e.g. "https://github.com/variant-inc/iaac-talos-flux-platform/pull/72"
FRESHSERVICE_TICKET = ""             # e.g. "FS-12345"
LIVE_LOGIN_TS_UTC = ""               # e.g. "2026-06-25 14:30 UTC"
# =================================

import os
EMAIL = os.environ.get("ATLASSIAN_EMAIL", "doke@usxpress.com")
TOKEN = os.environ.get("ATLASSIAN_TOKEN", "")
if not TOKEN:
    for candidate in [
        "/workspaces/eks_code/scripts/push-to-confluence.sh",
        os.path.expanduser("~/work/eks_code/scripts/push-to-confluence.sh"),
    ]:
        p = Path(candidate)
        if p.exists():
            for ln in p.read_text().splitlines():
                if ln.startswith("CONFLUENCE_TOKEN="):
                    TOKEN = ln.split("=", 1)[1].strip().strip('"').strip("'")
                    break
            if TOKEN:
                break
assert TOKEN, "Set ATLASSIAN_TOKEN env var or place the token script at the expected codespace/WSL paths."
BASE = "https://usxpress.atlassian.net"
auth = base64.b64encode(f"{EMAIL}:{TOKEN}".encode()).decode()
HEADERS = {"Authorization": f"Basic {auth}", "Accept": "application/json", "Content-Type": "application/json"}

if not all([CLIENT_ID, GRAFANA_PR, FRESHSERVICE_TICKET, LIVE_LOGIN_TS_UTC]):
    raise SystemExit("EDIT-ME fields not filled in.")

text = f"""{LIVE_LOGIN_TS_UTC} -- Azure AD SSO LIVE.

App registration:
- Application (client) ID: {CLIENT_ID}
- USXPress AAD tenant: bbb5a66d-5c9f-482a-969a-a40304b6bc8d
- Freshservice ticket that provisioned: {FRESHSERVICE_TICKET}

Secret stored in AWS SM: {SECRET_SM_ARN}

Grafana HelmRelease flipped enabled: false -> true via {GRAFANA_PR}

End-to-end test: Doke logged into https://grafana.op-dev.usxpress.io via corporate AAD credentials at {LIVE_LOGIN_TS_UTC}. Group claims arriving in token. RBAC mapping (next phase) tracked separately.

Closes the last gap from observability Phase 4 / INFRA-1520. Parent INFRA-1520 stays Done; this sub-ticket Done."""


def adf(t):
    blocks = []
    for para in t.strip().split("\n\n"):
        lines = para.split("\n")
        content = []
        for i, l in enumerate(lines):
            if i > 0:
                content.append({"type": "hardBreak"})
            if l:
                content.append({"type": "text", "text": l})
        blocks.append({"type": "paragraph", "content": content})
    return {"type": "doc", "version": 1, "content": blocks}


def api(method, path, body=None):
    req = urllib.request.Request(f"{BASE}{path}", data=json.dumps(body).encode() if body else None, method=method, headers=HEADERS)
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read().decode() or "{}")


req = urllib.request.Request(f"{BASE}/rest/api/3/issue/INFRA-1558/comment", data=json.dumps({"body": adf(text)}).encode(), method="POST", headers=HEADERS)
with urllib.request.urlopen(req) as r:
    print(f"  INFRA-1558 commented (id {json.loads(r.read().decode())['id']})")

tres = api("GET", "/rest/api/3/issue/INFRA-1558/transitions")
tid = {t["name"]: t["id"] for t in tres["transitions"]}
for name in ("Done", "Closed", "Resolved", "Complete"):
    if name in tid:
        api("POST", "/rest/api/3/issue/INFRA-1558/transitions", {"transition": {"id": tid[name]}})
        print(f"  INFRA-1558 -> {name}")
        break

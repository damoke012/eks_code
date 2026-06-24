#!/usr/bin/env python3
"""Post Doke OTel sign-off + ADR + Confluence references on INFRA-1515 (already Done)."""
import json, urllib.request, base64
from pathlib import Path

EMAIL = "doke@usxpress.com"
TOKEN = ""
for ln in Path("/workspaces/eks_code/scripts/push-to-confluence.sh").read_text().splitlines():
    if ln.startswith("CONFLUENCE_TOKEN="):
        TOKEN = ln.split("=", 1)[1].strip().strip('"').strip("'")
        break
assert TOKEN
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
    req = urllib.request.Request(f"{BASE}{path}", data=json.dumps(body).encode() if body else None, method=method, headers=HEADERS)
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read().decode() or "{}")


res = api("POST", "/rest/api/3/issue/INFRA-1515/comment", {"body": adf("""2026-06-24 — Durable record shipped + cluster owner sign-off captured.

OTel out-of-scope decision (Decision 4): SIGNED OFF by Doke (cluster owner) 2026-06-24. With Vibin's departure cross-cluster sign-off authority transfers to Matt Hagden / Steve Duck; this on-prem decision will be cross-checked at the next cloud platform sync. If cloud disagrees we revisit before Phase 4.

ADR shipped to enterprise repo as iaac-drafts/jun24-observability-phase0-adr/op-dev/docs/decisions/ADR-001-observability-phase0.md — staged for PR against variant-inc/iaac-talos-flux-platform. Mirrors the 4 decisions plus rejected alternatives + operational locks + gotchas captured during implementation.

Confluence page drafted at iaac-drafts/jun24-observability-phase0-adr/confluence/ADR-001-observability-phase0.md — will publish under UI space, Talos parent (3320938539), title "Observability Phase 0 — Decision Lock (op-usxpress-dev)".

This makes INFRA-1515 closure durable beyond the Jira comment:
- ADR in repo = engineers find it via grep + code review
- Confluence page = engineers find it via Confluence search + cross-team visibility
- Jira comment = audit trail

Ticket stays Done. Outstanding artifacts (ADR PR merge + Confluence publish) tracked under marathon umbrella INFRA-1544 — no separate ticket needed since they are documentation of an already-locked decision."""
)})
print(f"INFRA-1515 commented (id {res.get('id')})")
"""
"""

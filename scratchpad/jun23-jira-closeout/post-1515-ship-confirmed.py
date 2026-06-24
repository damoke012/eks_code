#!/usr/bin/env python3
"""Post final SHIPPED links on INFRA-1515 (Done) — PR + Confluence URLs."""
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


req = urllib.request.Request(
    f"{BASE}/rest/api/3/issue/INFRA-1515/comment",
    data=json.dumps({"body": adf("""2026-06-24 — Durable artifacts SHIPPED.

- ADR PR: variant-inc/iaac-talos-flux-platform PR #70 (https://github.com/variant-inc/iaac-talos-flux-platform/pull/70) — docs(adr-001): observability Phase 0 decision lock, base op-dev
- Confluence page: https://usxpress.atlassian.net/wiki/spaces/UI/pages/4586242049 — "Observability Phase 0 — Decision Lock (op-usxpress-dev)" under UI / Talos
- Jira ticket: this one (INFRA-1515) Done

All 3 durable records exist. Engineers will find the decision via grep on the repo, Confluence search, or Jira history. Phase 0 closeout fully ratified.

Remaining cross-team courtesy step (NOT a Phase 0 blocker): mention Decision 4 (OTel out-of-scope) to Matt Hagden / Steve Duck at next cloud platform sync to confirm cloud has no plans to add OTel in the near term that would force on-prem parity sooner."""
)}).encode(),
    method="POST",
    headers=HEADERS,
)
with urllib.request.urlopen(req) as r:
    res = json.loads(r.read().decode())
print(f"INFRA-1515 commented (id {res.get('id')})")

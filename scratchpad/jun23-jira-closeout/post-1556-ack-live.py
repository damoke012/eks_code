#!/usr/bin/env python3
"""Update INFRA-1556 closing-the-loop comment now that the Tim ack file is live."""
import json, urllib.request, base64
from pathlib import Path

EMAIL = "doke@usxpress.com"
TOKEN = ""
for ln in Path("/workspaces/eks_code/scripts/push-to-confluence.sh").read_text().splitlines():
    if ln.startswith("CONFLUENCE_TOKEN="):
        TOKEN = ln.split("=", 1)[1].strip().strip('"').strip("'")
        break
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
    f"{BASE}/rest/api/3/issue/INFRA-1556/comment",
    data=json.dumps({"body": adf("""2026-06-24 02:35 UTC -- Sixth README artifact now LIVE (parked for Tim handoff).

CLOUD-PLATFORM-ACK.md for Tim's iaac-risingwave-onprem is published at https://raw.githubusercontent.com/damoke012/iaac-risingwave-onprem-cloud-ack/main/CLOUD-PLATFORM-ACK.md (189 lines, clean single-file repo).

Teams handoff to Tim queued. He drops the file into his repo at his pace; we do not push to his repo per the binding [Protect RW on op-usxpress-dev] rule.

All 6 README artifacts now staged or shipped. INFRA-1556 stays Done."""
)}).encode(),
    method="POST",
    headers=HEADERS,
)
with urllib.request.urlopen(req) as r:
    res = json.loads(r.read().decode())
print(f"INFRA-1556 commented (id {res.get('id')})")

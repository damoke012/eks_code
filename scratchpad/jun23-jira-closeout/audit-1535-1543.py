#!/usr/bin/env python3
"""Audit INFRA-1535 + INFRA-1543 to see if Octopus admin access unblocks them."""
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
HEADERS = {"Authorization": f"Basic {auth}", "Accept": "application/json"}


def extract_text(adf):
    out = []
    def walk(n):
        if isinstance(n, dict):
            if n.get("type") == "text":
                out.append(n.get("text", ""))
            elif n.get("type") == "hardBreak":
                out.append("\n")
            for c in n.get("content", []) or []:
                walk(c)
            if n.get("type") in ("paragraph", "listItem", "bulletList"):
                out.append("\n")
    walk(adf or {})
    return "".join(out)


for key in ("INFRA-1535", "INFRA-1543"):
    req = urllib.request.Request(f"{BASE}/rest/api/3/issue/{key}?fields=summary,status,description,comment", headers=HEADERS)
    with urllib.request.urlopen(req) as r:
        d = json.loads(r.read().decode())
    print(f"\n========== {key} ==========")
    print(f"Summary: {d['fields']['summary']}")
    print(f"Status:  {d['fields']['status']['name']}")
    desc = d["fields"].get("description")
    if desc:
        print("\n--- Description ---")
        print(extract_text(desc)[:1500])
    comments = d["fields"].get("comment", {}).get("comments", [])
    print(f"\n--- Last {min(2,len(comments))} of {len(comments)} comments ---")
    for c in comments[-2:]:
        print(f"  {c.get('created','?')[:10]} by {c.get('author',{}).get('displayName','?')}:")
        print("  " + extract_text(c.get("body", {}))[:800].replace("\n", "\n  "))

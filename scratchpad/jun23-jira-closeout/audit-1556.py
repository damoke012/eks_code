#!/usr/bin/env python3
"""Audit current state of INFRA-1556."""
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

req = urllib.request.Request(f"{BASE}/rest/api/3/issue/INFRA-1556?fields=summary,status,description,comment", headers=HEADERS)
with urllib.request.urlopen(req) as r:
    d = json.loads(r.read().decode())

print("Summary:", d["fields"]["summary"])
print("Status: ", d["fields"]["status"]["name"])
print()

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

desc = d["fields"].get("description")
if desc:
    print("=== Description ===")
    print(extract_text(desc)[:2000])

comments = d["fields"].get("comment", {}).get("comments", [])
print(f"\n=== {len(comments)} comments ===")
for c in comments[-3:]:
    print(f"--- {c.get('created','?')[:10]} by {c.get('author',{}).get('displayName','?')} ---")
    print(extract_text(c.get("body", {}))[:1500])
    print()

#!/usr/bin/env python3
"""File the Hybrid AAD identity strategy epic + park INFRA-1558 under it."""
import json, urllib.request, urllib.error, base64
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
DOKE_ACCOUNT_ID = "712020:8d34bd84-b44f-4ec7-a839-478fedebc03d"


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
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        print(f"  HTTP {e.code}: {e.read().decode()[:600]}")
        raise


# ============ Create the Epic ============

epic_description = """Umbrella epic for the hybrid AAD identity strategy across on-prem Dev/QA/Prod clusters. Covers user SSO into web apps, workload identity federation for cluster-to-Azure-API calls, and the boundary with RW SQL user access (which is a separate pattern).

Design context preserved in cloud-platform memory file [onprem_aad_identity_strategy_jun25].

Three identity concerns:
1. User SSO into web apps (Grafana now, more later) -- OIDC flow against App Registration, AAD group claims map to roles
2. Workload identity federation -- App Reg federated credentials trusting OIDC tokens from k8s API; designed-for-future, no delivery scope today
3. RW SQL user access -- different pattern entirely (PG-level proxy or sync); flagged in [Idris's INFRA-1476]

Per-env App Registration topology recommendation:
- Dev + QA: shared App Reg with two redirect URIs (acceptable risk for non-prod)
- Prod: dedicated App Reg with single redirect URI (compliance + blast radius)
- Revisit if SOC2/audit demands per-env Dev/QA isolation

Terminology: these are App Registrations + Service Principals in AAD, NOT 'service accounts'. When coordinating with IT, language: 'OAuth 2.0 / OIDC App Registration in the USXPress tenant for [environment]'.

Sub-tasks to track under this epic:
1. Decide per-env App Reg topology (Dev+QA shared vs all-three-separate) -- pre-work for QA stand-up
2. AAD admin coordination with IT lead -- establish lifecycle ownership
3. Grafana Dev SSO -- was INFRA-1558, parking under this epic, executes alongside QA stand-up
4. Grafana QA SSO -- parallel with QA stand-up
5. Grafana Prod SSO -- when Prod cluster ready
6. Workload identity federation pattern doc (designed-for-future placeholder)
7. RW user access bridge coordination with Idris (link to INFRA-1476)

Tenant: USXPress (bbb5a66d-5c9f-482a-969a-a40304b6bc8d).

Why parked: filing INFRA-1558 in isolation risks Dev pattern diverging from QA/Prod. IT ticket has lead time; better to coordinate per-env strategy once than three times. QA cluster stand-up is the natural inflection point."""

create_body = {
    "fields": {
        "project": {"key": "INFRA"},
        "summary": "Hybrid AAD identity strategy for on-prem clusters (Dev/QA/Prod)",
        "issuetype": {"name": "Epic"},
        "labels": ["onprem", "identity", "AAD", "hybrid", "observability"],
        "assignee": {"accountId": DOKE_ACCOUNT_ID},
        "description": adf(epic_description),
    }
}

print("Creating epic...")
res = api("POST", "/rest/api/3/issue", create_body)
EPIC_KEY = res["key"]
print(f"  Epic created: {EPIC_KEY}")

# ============ Park INFRA-1558 under the epic ============

park_comment = f"""2026-06-25 -- PARKED under new umbrella epic {EPIC_KEY} (Hybrid AAD identity strategy for on-prem clusters).

Reasoning: filing this in isolation as a Dev-only Grafana SSO ticket risks the Dev pattern diverging from QA/Prod. The natural inflection point is the QA cluster stand-up, where the per-env App Registration topology (Dev+QA shared vs all-three-separate) can be decided coherently. IT ticket lead time also favors filing once with the full per-env strategy in hand.

Scope of this ticket NOT changing -- still 'register the AAD App for Grafana SSO on op-usxpress-dev'. Just the delivery timing.

Design context for the parking decision: cloud-platform memory file [onprem_aad_identity_strategy_jun25] captures the three identity concerns (user SSO, workload identity, RW SQL access boundary), per-env topology recommendation (Dev+QA shared, Prod dedicated), terminology (App Registrations not 'service accounts'), and IT coordination language.

Reopens for execution when: QA cluster stand-up timeline firms up, OR when corporate identity audit requirements change, OR when Grafana audience demand grows past the current ~5-engineer scope.

Until then: Grafana on op-usxpress-dev continues to use local admin auth via AWS SM secret op-usxpress-dev/platform/grafana. Functional, not aspirational."""

print(f"\nParking INFRA-1558 under {EPIC_KEY}...")
res = api("POST", "/rest/api/3/issue/INFRA-1558/comment", {"body": adf(park_comment)})
print(f"  INFRA-1558 commented (id {res.get('id')})")

# Try to set the parent epic on 1558 (Atlassian Cloud uses the parent field for epic link now)
try:
    api("PUT", "/rest/api/3/issue/INFRA-1558", {"fields": {"parent": {"key": EPIC_KEY}}})
    print(f"  INFRA-1558 parent set to {EPIC_KEY}")
except urllib.error.HTTPError as e:
    print(f"  Could not set parent (will need manual link in Jira UI): {e}")

# Move 1558 from In Progress back to To Do to reflect "parked, not actively worked"
tres = api("GET", "/rest/api/3/issue/INFRA-1558/transitions")
tid = {t["name"]: t["id"] for t in tres["transitions"]}
print(f"  Available transitions for 1558: {list(tid)}")
for n in ("To Do", "Selected for Development", "Backlog", "Open"):
    if n in tid:
        api("POST", "/rest/api/3/issue/INFRA-1558/transitions", {"transition": {"id": tid[n]}})
        print(f"  INFRA-1558 -> {n}")
        break
else:
    print(f"  No suitable park-state available; leaving In Progress with the comment as the marker")

print(f"\nDone. New epic: https://usxpress.atlassian.net/browse/{EPIC_KEY}")

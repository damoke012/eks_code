#!/usr/bin/env python3
"""Add resolution-status comments to existing INFRA tickets touched by the marathon."""
import json
import os
import urllib.request
import urllib.error
import base64

EMAIL = os.environ['ATLASSIAN_EMAIL']
TOKEN = os.environ['ATLASSIAN_TOKEN']
BASE = "https://usxpress.atlassian.net"
auth = base64.b64encode(f"{EMAIL}:{TOKEN}".encode()).decode()
HEADERS = {
    "Authorization": f"Basic {auth}",
    "Accept": "application/json",
    "Content-Type": "application/json",
}


def adf_text(text):
    """Plain-text ADF document."""
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


def comment(issue_key, text):
    res = api("POST", f"/rest/api/3/issue/{issue_key}/comment", {"body": adf_text(text)})
    print(f"  {issue_key} commented (id {res.get('id')})")


# === INFRA-1535: OnPremise Octopus space ===
comment("INFRA-1535", """Status update 2026-06-23 (jun23 marathon closeout):

This ticket remains an EXTERNAL BLOCKER — completion requires Octopus admin token Doke does NOT have. Action item is with Octopus admin to provision the OnPremise space.

What we can land now (no admin needed):
- IaC for the worker pool config (parked in iaac-octopus-onprem repo)
- README in iaac-octopus-onprem documenting the bootstrap pattern (see INFRA-1556)

What requires admin:
- Create OnPremise space in Octopus
- Provision API token scoped to that space
- Add space connection settings to iaac-octopus-onprem TF

Relates: INFRA-1543, INFRA-1544 (marathon umbrella).""")

# === INFRA-1542: Flux bootstrap automation ===
comment("INFRA-1542", """Status update 2026-06-23 (jun23 marathon closeout):

Manual Flux bootstrap RUNBOOK has been shipped to enterprise iaac-talos/deploy/docs/troubleshooting/runbooks/flux-bootstrap-from-scratch.md (via PR variant-inc/iaac-talos #45).

This closes the documentation gap and unblocks new-cluster bring-up (e.g., QA cluster tomorrow) using the runbook as a step-by-step procedure.

What this ticket STILL covers (and remains To Do for follow-up sprint):
- Full IaC automation of Flux bootstrap (currently TF-bootstrap runs once at cluster creation; the runbook covers the manual recovery path)
- Add bootstrap state assertion + drift detection
- Make the Octopus apply idempotent if Flux SSH key is rotated

Not blocking restore-readiness or QA bring-up — runbook is sufficient.

Relates: INFRA-1544 (marathon umbrella), INFRA-1554 (catalog ship — Done).""")

# === INFRA-1543: OnPremise Octopus worker pool IaC ===
comment("INFRA-1543", """Status update 2026-06-23 (jun23 marathon closeout):

Tied to INFRA-1535. Same external blocker — needs Octopus admin token to provision OnPremise space, after which we can land the worker pool + space config as IaC in iaac-octopus-onprem.

Until then: README in iaac-octopus-onprem will document the target pattern (see INFRA-1556).

Relates: INFRA-1535, INFRA-1544 (marathon umbrella).""")

print("Done.")

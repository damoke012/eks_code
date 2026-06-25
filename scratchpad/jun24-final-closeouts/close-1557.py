#!/usr/bin/env python3
"""Close INFRA-1557 after cloud-ops responds. Edit the EVIDENCE block, then run."""
import json, urllib.request, urllib.error, base64
from pathlib import Path

# ============ EDIT-ME ============
# Pick ONE outcome and fill in the relevant field.
OUTCOME = "accepted_risk"      # one of: "owned_by_cloud_ops" | "accepted_risk" | "doke_implemented"

# If OUTCOME == "owned_by_cloud_ops": their follow-up ticket # / link
CLOUD_OPS_TICKET = ""          # e.g. "PLAT-1234" or full URL

# If OUTCOME == "accepted_risk": who acked + the date of the ack (YYYY-MM-DD)
RISK_ACK_BY = ""               # e.g. "Matt Higdon"
RISK_ACK_DATE = ""             # e.g. "2026-06-25"

# If OUTCOME == "doke_implemented": the PR # / link
IMPLEMENTATION_PR = ""         # e.g. "https://github.com/variant-inc/cloud-platform-tf/pull/123"
# =================================

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


bodies = {
    "owned_by_cloud_ops": f"""2026-MM-DD -- Cloud-ops owns the implementation.
Tracked under: {CLOUD_OPS_TICKET}
Closing INFRA-1557 as advisory delivered + accepted; CRR implementation tracked by cloud-ops on their own ticket.""",
    "accepted_risk": f"""2026-MM-DD -- Risk acknowledged + accepted (no action this cycle).
Acked by: {RISK_ACK_BY} ({RISK_ACK_DATE})
Cloud-ops reviewed the single-region S3 risk for the on-prem Talos TF state bucket and accepted as residual risk for now. Revisit trigger: next region-level S3 incident OR the next cluster recovery rehearsal -- whichever comes first.
Documented in memory under [[onprem-cluster-tf-state-location]] and [[onprem-safety]] Rule 6.""",
    "doke_implemented": f"""2026-MM-DD -- CRR enabled by Cloud Platform team.
PR: {IMPLEMENTATION_PR}
Source bucket lazy-tf-state-65v583i6my68y6x9 (us-east-2) now replicating to sibling bucket in us-west-2 same account. Versioning enabled on both. CRR role provisioned. State files visible in destination. Single-region S3 dependency closed.""",
}

assert OUTCOME in bodies, f"OUTCOME must be one of: {list(bodies)}"
text = bodies[OUTCOME]
if "<" in text or text.endswith(": ") or ": \n" in text:
    raise SystemExit("EDIT-ME fields not filled in. Set the relevant variables at the top of the script.")

req = urllib.request.Request(f"{BASE}/rest/api/3/issue/INFRA-1557/comment", data=json.dumps({"body": adf(text)}).encode(), method="POST", headers=HEADERS)
with urllib.request.urlopen(req) as r:
    print(f"  INFRA-1557 commented (id {json.loads(r.read().decode())['id']})")

# Find Done transition
tres = api("GET", "/rest/api/3/issue/INFRA-1557/transitions")
tid = {t["name"]: t["id"] for t in tres["transitions"]}
for name in ("Done", "Closed", "Resolved", "Complete"):
    if name in tid:
        api("POST", "/rest/api/3/issue/INFRA-1557/transitions", {"transition": {"id": tid[name]}})
        print(f"  INFRA-1557 -> {name}")
        break
else:
    print(f"  No Done-like transition available. Got: {list(tid)}")

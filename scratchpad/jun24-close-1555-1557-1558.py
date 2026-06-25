#!/usr/bin/env python3
"""Close-out push for INFRA-1555, INFRA-1557, INFRA-1558.

- INFRA-1557 -> In Progress with advisory delivered comment (closes on cloud-ops ack)
- INFRA-1558 -> In Progress with full IT request body (closes when OAuth app provisioned)
- INFRA-1555 -> stays TO DO with runbook reference + Tim courtesy-ping draft
"""
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
        print(f"  HTTP {e.code}: {e.read().decode()[:400]}")
        raise


def comment(key, text):
    res = api("POST", f"/rest/api/3/issue/{key}/comment", {"body": adf(text)})
    print(f"  {key} commented (id {res.get('id')})")


def transitions(key):
    res = api("GET", f"/rest/api/3/issue/{key}/transitions")
    return {t["name"]: t["id"] for t in res.get("transitions", [])}


def transition(key, name):
    avail = transitions(key)
    if name not in avail:
        print(f"  {key} can't go to '{name}' -- available: {list(avail.keys())}")
        return False
    api("POST", f"/rest/api/3/issue/{key}/transitions", {"transition": {"id": avail[name]}})
    print(f"  {key} -> {name}")
    return True


# ============ INFRA-1557 ============

comment("INFRA-1557", """2026-06-24 -- Advisory finalized, ready for cloud-ops handoff.

Bucket lazy-tf-state-65v583i6my68y6x9 in us-east-2 (USX-Dev account 700736442855) holds the on-prem op-usxpress-dev Talos cluster's machine secrets. This is the ONLY durable source of truth for reconstructing a working talosconfig in a recovery scenario -- per the 2026-06-17 CP OOM cascade procedure. Single-region S3 dependency is a documented gap.

Recommended action (for cloud-ops to execute): enable S3 Cross-Region Replication to a sibling bucket in us-west-2 same account. Versioning enabled on both source + destination. Standard CRR IAM role.

Cost: under $5/month given state file size; effectively free relative to DR value.

Why cloud-ops (not us): bucket is in cloud-ops-managed USX-Dev account; cross-region S3 patterns should match canonical org pattern; IAM role creation requires cloud-ops review.

Full advisory: iaac-drafts/jun24-closeout-prep/INFRA-1557-tf-state-crr-advisory.md (shipped on damoke012/eks_code transfer/rook-ceph-safe-reroll-jun17).

DELIVERY: handing off via Teams DM to org owners (currently buddy-james, higdonmatthew, svivesusx -- need to confirm whether Matt Higdon + S. Vives are the post-Vibin sign-off authorities, or whether the original Matt Hagden + Steve Duck assignment from session memory is the correct lookup).

Acceptance: this ticket closes on cloud-ops acknowledgement (own ticket / risk-accept / pair-up agreement). Not implementation -- that's their scope.""")

transition("INFRA-1557", "In Progress")

# ============ INFRA-1558 ============

comment("INFRA-1558", """2026-06-24 -- IT request ready to file.

REQUEST FOR: Azure AD OAuth 2.0 / OIDC app registration on the USXPress AAD tenant (bbb5a66d-5c9f-482a-969a-a40304b6bc8d).

PURPOSE: SSO for on-prem Grafana at https://grafana.op-dev.usxpress.io. Grafana already shipped with the AAD OIDC skeleton config (enabled: false); we flip the flag once we receive the Application (client) ID + client secret.

EXACT APP CONFIG:
- Display name: Grafana -- op-usxpress-dev (on-prem)
- Description: On-prem Grafana dashboard SSO for Cloud Platform team -- INFRA-1558
- Account types: Single tenant (USXPress only)
- Platform: Web
- Redirect URI: https://grafana.op-dev.usxpress.io/login/azuread
- Logout URL: https://grafana.op-dev.usxpress.io/logout
- API permissions (delegated): openid, email, profile, User.Read, GroupMember.Read.All
- Admin consent: required for GroupMember.Read.All (tenant-wide)
- Token configuration: Groups claim emitted (security groups, in access + ID tokens)
- Client secret: 12-month expiry, description "Grafana on-prem SSO 2026-06-24"

DELIVERY BACK TO US (secure channel only -- 1Password vault, NOT chat/Teams plain):
- Application (client) ID
- Tenant ID confirmation (we have bbb5a66d-5c9f-482a-969a-a40304b6bc8d -- please confirm)
- Client secret VALUE (only visible at creation time in the portal)

POST-RECEIPT (our side): write secret to AWS SM op-usxpress-dev/platform/grafana/azure-ad, flip enabled: true in Grafana HelmRelease values, Flux reconcile, browser-test corporate AAD login.

Full request text: iaac-drafts/jun24-closeout-prep/INFRA-1558-azure-ad-oauth-app-request.md (shipped on damoke012/eks_code transfer/rook-ceph-safe-reroll-jun17).

DELIVERY: filing as Freshservice ticket to IT helpdesk for routing to USXPress Application Administrator. Parent INFRA-1520 stays Done; this sub-ticket closes when OAuth app provisioned and live login verified.""")

transition("INFRA-1558", "In Progress")

# ============ INFRA-1555 ============

comment("INFRA-1555", """2026-06-24 -- Runbook ready; awaiting Tim window for courtesy coordination.

Full migration runbook: iaac-drafts/jun24-closeout-prep/INFRA-1555-postgres-migration-runbook.md (shipped on damoke012/eks_code transfer/rook-ceph-safe-reroll-jun17). Covers Velero pre-backup, Flux suspend, PVC delete + recreate with Helm adoption labels per [[feedback-helm-no-auto-pvc-restore]], scale-up, post-verify, rollback path.

DECISION POINT pre-execution: confirm whether rw-2 Postgres meta-store is rebuildable (RW rebuilds meta from compute nodes -> no data restore step needed) OR holds operator state (must add Velero file-level restore step). Will verify by reading rw-2 chart values + asking Tim if unclear.

BLAST RADIUS: rw-2 namespace only (Cloud-Platform's validation instance). NOT Tim's risingwave namespace. Per [[feedback-protect-rw-onprem-workload]] -- courtesy ping to Tim before executing, not approval requirement.

NEXT STEP: send Tim the courtesy heads-up message (drafted in the runbook), then execute when his window aligns. Estimated 45 min focused (Velero pre-backup runs in background while we touch PVCs).

Stays TO DO until Tim ack received; transitions to In Progress when execution starts.""")

print("Done.")

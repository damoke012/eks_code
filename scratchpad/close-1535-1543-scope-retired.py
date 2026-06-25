#!/usr/bin/env python3
"""Close INFRA-1535 + INFRA-1543 as scope-retired (2026-06-25)."""
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
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read().decode() or "{}")


def comment(key, text):
    res = api("POST", f"/rest/api/3/issue/{key}/comment", {"body": adf(text)})
    print(f"  {key} commented (id {res.get('id')})")


def transition(key, name):
    tres = api("GET", f"/rest/api/3/issue/{key}/transitions")
    tid = {t["name"]: t["id"] for t in tres["transitions"]}
    if name in tid:
        api("POST", f"/rest/api/3/issue/{key}/transitions", {"transition": {"id": tid[name]}})
        print(f"  {key} -> {name}")
        return True
    print(f"  {key} can't transition to '{name}', available: {list(tid)}")
    return False


# ============ INFRA-1535 ============

comment("INFRA-1535", """2026-06-25 -- CLOSING as scope-retired.

Original cascade (cloud-eks ClusterSecretStore terminal-failure blocking app-secrets + octopus-worker Kustomizations for 32 days) was RESOLVED on 2026-06-22 by removing the orphan geoenrichment ExternalSecret that was the sole consumer of the broken CSS. No current workload on op-usxpress-dev requires cross-cluster ESO.

Per [[onprem-prod-readiness-cross-cluster-eso-spof]] the cross-cluster bridge pattern is POC-only SPOF; for production workloads the canonical pattern is direct AWS SM source (see [[cloud-to-onprem-workload-patterns-jun02]] -- mirror-release.py + cross-cluster-eso + Kyverno mutation, where 'cross-cluster-eso' reads from AWS SM not a peer k8s cluster).

Standing up the OnPremise Octopus space + bootstrap runbook would deliver no current operational value (no workload consumes the result) and lock in infrastructure for a pattern we have already decided not to scale.

Scope-retired with full preservation for revival:
- Scaffold IaC: iaac-drafts/tracks-4-5-restore-jun22/octopus-onprem-scaffold/ (Space + Environment + Project + Lifecycle TF + PowerShell runbook body)
- Target-pattern README shipped to variant-inc/iaac-octopus-onprem PR #3 (merged 2026-06-24 via INFRA-1556)
- Full revival runbook documented at memory file onprem_cross_cluster_eso_retired_jun25.md

Revival triggers documented in the memory file. Estimated revival time: ~2.5 hr.

Closing as Done with workaround + scope-retired rationale captured in memory. INFRA-1543 closing in parallel for the same reason.""")

transition("INFRA-1535", "Done")

# ============ INFRA-1543 ============

comment("INFRA-1543", """2026-06-25 -- CLOSING as scope-retired (tied to INFRA-1535).

The OnPremise Octopus worker pool + space IaC was filed to codify the infrastructure that INFRA-1535's runbook would target. Since INFRA-1535's underlying problem was resolved 2026-06-22 (geoenrichment ExternalSecret removal unblocked the Kustomization cascade) and no current workload requires the cross-cluster ESO pattern, standing up the worker pool would create infrastructure with nothing to run on it.

Scaffold IaC preserved at iaac-drafts/tracks-4-5-restore-jun22/octopus-onprem-scaffold/ for revival alongside INFRA-1535 when a future workload genuinely requires the OnPremise space + worker pool.

Closing as Done with revival path documented in memory file onprem_cross_cluster_eso_retired_jun25.md.""")

transition("INFRA-1543", "Done")

print("Done.")

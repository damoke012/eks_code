#!/usr/bin/env python3
"""Move actively-worked-on marathon tickets to In Progress + comment.
Verify Done state on the 10 completed child tasks.
List status of external-blocker tickets for the wrap-up summary.
"""
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
        print(f"  ERROR {e.code} {method} {path}: {e.read().decode()}")
        raise


def status(key):
    res = api("GET", f"/rest/api/3/issue/{key}?fields=summary,status")
    return res['fields']['status']['name'], res['fields']['summary']


def transition(key, target_name):
    res = api("GET", f"/rest/api/3/issue/{key}/transitions")
    for t in res.get("transitions", []):
        if t["name"].lower() == target_name.lower():
            api("POST", f"/rest/api/3/issue/{key}/transitions", {"transition": {"id": t["id"]}})
            print(f"  {key} -> {target_name}")
            return
    print(f"  WARN: no transition '{target_name}' on {key}; available: {[t['name'] for t in res.get('transitions',[])]}")


def comment(key, text):
    res = api("POST", f"/rest/api/3/issue/{key}/comment", {"body": adf(text)})
    print(f"  {key} commented (id {res.get('id')})")


# === STEP 1: List current status of all marathon tickets ===
print("=" * 60)
print("Current status — marathon tickets (INFRA-1544..1557)")
print("=" * 60)
for n in range(1544, 1558):
    try:
        st, sm = status(f"INFRA-{n}")
        print(f"  INFRA-{n} [{st:14s}] {sm[:70]}")
    except Exception:
        print(f"  INFRA-{n} (not found / no access)")

print()
print("Current status — external-blocker tickets")
print("=" * 60)
for n in [1535, 1542, 1543]:
    try:
        st, sm = status(f"INFRA-{n}")
        print(f"  INFRA-{n} [{st:14s}] {sm[:70]}")
    except Exception:
        print(f"  INFRA-{n} (not found / no access)")

# === STEP 2: Move actively-worked-on to In Progress + comment ===
print()
print("=" * 60)
print("Transitioning to In Progress + adding status comments")
print("=" * 60)

# INFRA-1544 (Epic): work is active across 3 in-progress child tasks
transition("INFRA-1544", "In Progress")
comment("INFRA-1544", """Status update 2026-06-23 closeout:

10 of 13 child tasks are Done:
- INFRA-1545 (Velero), 1546 (etcd-backup), 1547 (TF IRSA + talosconfig SM),
  1548 (Prometheus ceph-block), 1549 (rw-2 prometheus-server ceph-block),
  1550 (rw-2 operator supplemental ClusterRole), 1551 (Ceph mgr memory),
  1552 (External-DNS), 1553 (default branch flip), 1554 (catalog initial 6 + runbook)

3 child tasks remain:
- INFRA-1555 (Postgres migration) — To Do, needs Tim window
- INFRA-1556 (READMEs across 6 repos) — In Progress, PRs being shipped now
- INFRA-1557 (TF state CRR advisory) — In Progress, drafted + ready to send to cloud-ops

Epic moves to In Progress until 1556/1557 land. 1555 will close out separately under Tim's window.""")

# INFRA-1556: actively shipping via 6 WSL PRs RIGHT NOW
transition("INFRA-1556", "In Progress")
comment("INFRA-1556", """Status update 2026-06-23 closeout:

Drafts reconciled with actual enterprise repo state (read from WSL-side tarballs):
- iaac-talos (611 lines) — MERGED with existing 149-line generic README. Variable tables + deploy steps preserved.
- iaac-talos-flux-cluster (546 lines) — replaces 26-byte stub. Added legacy bm-dev/dpl/dpl2/dpl2.bak status table.
- iaac-talos-flux-platform (1676 lines) — replaces 27-byte stub. Expanded from 8 to 34 components (added arc, cilium-lb, cilium-hygiene, cross-cluster-app-secrets, ecr-credentials, grafana, istio-csr/ingress/namespace, istiod-health, keda, kyverno + kyverno-policies, octopus-worker, pod-identity-webhook, reloader, risingwave-routes, trust-manager + trust-manager-bundle; split rook-ceph operator vs cluster).
- iaac-risingwave-2 (428 lines) — verified against actual manifests (clusterrole-supplemental.yaml confirmed).
- iaac-risingwave-onprem (189 lines) — ships as CLOUD-PLATFORM-ACK.md (sibling file, not stomping Tim's README).
- iaac-octopus-onprem (365 lines) — target-pattern doc (blocked on admin token, INFRA-1535).

Total: 3815 lines across 6 READMEs. v2 tarball sha256 a62f24b935fe97f5f1cc02824091adf49d8299d058fd759ae64d58281b866b0f.

WSL ship-block (PUSH-TO-ENTERPRISE-2026-06-23.md) walks 6 PRs step-by-step. Currently shipping.

Transitions to Done after all 6 PRs land.""")

# INFRA-1557: advisory drafted, ready to send
transition("INFRA-1557", "In Progress")
comment("INFRA-1557", """Status update 2026-06-23 closeout:

Advisory DRAFTED — full text at iaac-drafts/jun23-closeout/tf-state-cross-region-advisory.md on damoke012/eks_code transfer branch.

Raw URL:
https://raw.githubusercontent.com/damoke012/eks_code/transfer/rook-ceph-safe-reroll-jun17/iaac-drafts/jun23-closeout/tf-state-cross-region-advisory.md

Asks cloud-ops to:
1. Add cross-region or cross-account replication for lazy-tf-state-65v583i6my68y6x9
2. Confirm MFA-delete or guarded policy
3. Send back RPO/RTO for tfstate

Next step: paste body into Slack DM / email to cloud-ops lead. Transitions to Done once cloud-ops acknowledges + commits to a replication plan (or confirms one already exists).""")

# === STEP 3: Re-confirm the 10 Done child tasks ===
print()
print("=" * 60)
print("Re-confirming Done state on 10 marathon child tasks")
print("=" * 60)
for n in range(1545, 1555):
    try:
        st, sm = status(f"INFRA-{n}")
        marker = "OK" if st.lower() == "done" else "NOT DONE"
        print(f"  INFRA-{n} [{st:14s}] {marker}  {sm[:60]}")
    except Exception:
        print(f"  INFRA-{n} (not found)")

print()
print("Done.")

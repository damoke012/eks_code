#!/usr/bin/env python3
"""
File the 7 follow-up tickets from the 2026-05-29 networking/CySec call review.

Strategy mirrors file-rw-onprem-followup-tickets.py:
- Look up the parent ticket type for each. If Epic/Story/Task → file as Sub-task.
- Otherwise (e.g., parent is itself a Sub-task) → file as Task + add a Relates link.

After filing, prints a Markdown table of (slug, key, parent, type) for easy
review + the user can run `git mv` to move drafts to sent/ with INFRA-xxxx names.

Reuses md_to_adf + auth helpers from file-jira-slate.py.
"""

import base64
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from importlib import import_module

REPO_ROOT = Path(__file__).resolve().parent.parent
DRAFTS_DIR = REPO_ROOT / "jira/drafts"
RESULTS = Path("/tmp/networking-call-tickets-results.json")

sys.path.insert(0, str(Path(__file__).resolve().parent))
slate = import_module("file-jira-slate")

# Slate of drafts. Each tuple: (filename, parent_key, fallback_parent_if_subtask_blocked)
# Most go under INFRA-1492 (TCP/SNI umbrella). Some under INFRA-472 (initiative).
SLATE = [
    ("2026-06-01-automate-le-cert-rotation.md",            "INFRA-1492", "INFRA-472"),
    ("2026-06-01-prometheus-cert-expiry-alerting.md",      "INFRA-1492", "INFRA-472"),
    ("2026-06-01-publish-caa-record-usxpress-io.md",       "INFRA-1492", "INFRA-472"),
    ("2026-06-01-wiz-ebpf-onboarding-op-usxpress-dev.md",  "INFRA-472",  None),
    ("2026-06-01-etcd-encryption-at-rest-research.md",     "INFRA-472",  None),
    ("2026-06-01-document-eks-etcd-encryption-posture.md", "INFRA-472",  None),  # link to research after both filed
    ("2026-06-01-cross-cluster-dr-bootstrap-design.md",    "INFRA-472",  None),
]


def main():
    api = slate.api
    parse_draft = slate.parse_draft
    md_to_adf = slate.md_to_adf

    # 1. Idris accountId — leaving here because the helper looks it up; we assign to Doke.
    # Actually, the 7 tickets assign to Doke (not Idris). Get Doke's accountId.
    s, users = api("GET", "/rest/api/3/user/search?query=damoke012&maxResults=10")
    doke_id = None
    if isinstance(users, list):
        for u in users:
            em = (u.get("emailAddress") or "").lower()
            nm = (u.get("displayName") or "").lower()
            if "doke" in nm or "damoke012" in em or "doke@" in em:
                doke_id = u.get("accountId"); break
    if not doke_id:
        # Try search by Doke's known email
        s, users = api("GET", "/rest/api/3/user/search?query=doke@usxpress.com&maxResults=10")
        if isinstance(users, list) and users:
            doke_id = users[0].get("accountId")
    print(f"Doke accountId: {doke_id}")

    # 2. Project + issuetype IDs.
    s, proj = api("GET", "/rest/api/3/project/INFRA")
    type_by_name = {it.get("name"): it.get("id") for it in (proj.get("issueTypes") or [])}
    story_id = type_by_name.get("Story")
    task_id = type_by_name.get("Task")
    subtask_id = type_by_name.get("Sub-task") or type_by_name.get("Subtask")
    print(f"Issue type IDs: Story={story_id} Task={task_id} Subtask={subtask_id}\n")

    # 3. Cache parent issue types so we know subtask vs link
    parent_types = {}
    parents_to_lookup = set()
    for _, p, fp in SLATE:
        parents_to_lookup.add(p)
        if fp:
            parents_to_lookup.add(fp)
    for key in parents_to_lookup:
        s, resp = api("GET", f"/rest/api/3/issue/{key}?fields=issuetype,summary")
        if s == 200:
            parent_types[key] = resp.get("fields", {}).get("issuetype", {}).get("name", "")
            print(f"  Parent {key}: {parent_types[key]}")
        else:
            parent_types[key] = "UNKNOWN"
            print(f"  Parent {key}: lookup failed HTTP {s}")
    print()

    can_subtask = {"Epic", "Story", "Task"}

    # 4. File each draft
    results = {}
    for fname, parent_key, fallback_parent in SLATE:
        path = DRAFTS_DIR / fname
        if not path.exists():
            print(f"!! missing draft: {fname}")
            results[fname] = {"status": "MISSING"}
            continue

        meta, body = parse_draft(path)
        m = re.search(r"^#\s+(.+)$", body, re.MULTILINE)
        title = m.group(1) if m else fname
        title = re.sub(r"\*\*", "", title).strip("`").strip()
        body_no_title = re.sub(r"^#\s+.+\n", "", body, count=1, flags=re.MULTILINE)
        adf = md_to_adf(body_no_title)

        labels = meta.get("labels") or []
        if isinstance(labels, str):
            labels = [labels]
        labels = [re.sub(r"[^A-Za-z0-9_\-.]", "-", l.strip()) for l in labels if l.strip()]
        for default in ("onprem-networking", "may29-call-followup"):
            if default not in labels:
                labels.append(default)

        # Decide strategy
        ptype = parent_types.get(parent_key, "")
        use_parent = parent_key
        if ptype not in can_subtask and fallback_parent:
            fp_type = parent_types.get(fallback_parent, "")
            if fp_type in can_subtask:
                use_parent = fallback_parent
                ptype = fp_type
                print(f"  ({fname}: parent {parent_key} is {parent_types.get(parent_key)} — falling back to {fallback_parent})")

        if ptype in can_subtask and subtask_id:
            payload = {"fields": {
                "project": {"key": "INFRA"},
                "summary": title,
                "description": adf,
                "issuetype": {"id": subtask_id},
                "parent": {"key": use_parent},
                "labels": labels,
            }}
            kind_str = f"Sub-task of {use_parent}"
        else:
            payload = {"fields": {
                "project": {"key": "INFRA"},
                "summary": title,
                "description": adf,
                "issuetype": {"id": task_id or story_id},
                "labels": labels,
            }}
            kind_str = f"Task (will link to {parent_key})"

        if doke_id:
            payload["fields"]["assignee"] = {"accountId": doke_id}

        print(f"[POST] {title[:90]}  → {kind_str}")
        s, resp = api("POST", "/rest/api/3/issue", payload)
        if s in (200, 201):
            new_key = resp.get("key")
            print(f"  CREATED {new_key}")
            results[fname] = {"status": "OK", "key": new_key, "parent_used": use_parent, "kind": kind_str}

            # If not sub-tasked, add Relates link
            if "Sub-task" not in kind_str:
                link_payload = {
                    "type": {"name": "Relates"},
                    "inwardIssue": {"key": new_key},
                    "outwardIssue": {"key": parent_key},
                }
                ls, _ = api("POST", "/rest/api/3/issueLink", link_payload)
                print(f"  Link to {parent_key}: HTTP {ls}")
        else:
            print(f"  FAIL HTTP {s}  {json.dumps(resp)[:300]}")
            results[fname] = {"status": "FAIL", "err": resp}

    print("\n=== SUMMARY ===")
    print(f"{'STATUS':6} {'KEY':14} {'PARENT/LINK':16} FILE")
    for fname, r in results.items():
        print(f"{r.get('status'):6} {r.get('key','-'):14} {r.get('parent_used','-'):16} {fname}")
    RESULTS.write_text(json.dumps(results, indent=2))
    print(f"\nResults: {RESULTS}")

    return 0 if all(r.get("status") == "OK" for r in results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""
File the two RW onprem PR #7 follow-up tickets to variant-inc Atlassian (INFRA project).

Drafts:
- jira/drafts/2026-05-29-rw-onprem-remove-dead-postgres-hr.md
- jira/drafts/2026-05-29-rw-onprem-adopt-pg-postgresql-into-source.md

Parent strategy:
- Looks up INFRA-1487 to determine its issuetype.
- If INFRA-1487 is an Epic or Story: file the new tickets as Sub-tasks of INFRA-1487.
- Otherwise: file as Tasks/Stories linked to INFRA-1487 via "relates to".

Reuses the markdown→ADF converter from file-jira-slate.py.

Writes results JSON to /tmp/rw-onprem-followup-results.json.
"""

import base64
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

# Re-import the helper functions from the slate filer (same dir).
sys.path.insert(0, str(Path(__file__).resolve().parent))
from importlib import import_module
slate = import_module("file-jira-slate")  # noqa

REPO_ROOT = Path(__file__).resolve().parent.parent
DRAFTS_DIR = REPO_ROOT / "jira/drafts"
RESULTS = Path("/tmp/rw-onprem-followup-results.json")

PARENT_KEY = "INFRA-1487"

DRAFTS = [
    "2026-05-29-rw-onprem-remove-dead-postgres-hr.md",      # A1
    "2026-05-29-rw-onprem-adopt-pg-postgresql-into-source.md",  # A2
]


def main():
    # Reuse auth + helpers from slate.
    api = slate.api
    parse_draft = slate.parse_draft
    md_to_adf = slate.md_to_adf

    # 1. Look up Idris.
    s, users = api("GET", "/rest/api/3/user/search?query=ifagbemi&maxResults=10")
    idris_id = None
    if isinstance(users, list):
        for u in users:
            em = (u.get("emailAddress") or "").lower()
            nm = (u.get("displayName") or "").lower()
            if "idris" in nm or "fagbemi" in nm or "ifagbemi" in em:
                idris_id = u.get("accountId")
                break
    print(f"Idris accountId: {idris_id}")

    # 2. Project + issuetype IDs.
    s, proj = api("GET", "/rest/api/3/project/INFRA")
    print(f"Project: {proj.get('name')}")
    type_by_name = {it.get("name"): it.get("id") for it in (proj.get("issueTypes") or [])}
    print(f"Issue types: {list(type_by_name.keys())}")
    story_id = type_by_name.get("Story")
    task_id = type_by_name.get("Task")
    subtask_id = type_by_name.get("Sub-task") or type_by_name.get("Subtask")
    print(f"Story={story_id}  Task={task_id}  Subtask={subtask_id}")

    # 3. Look up the parent to decide strategy.
    s, parent = api("GET", f"/rest/api/3/issue/{PARENT_KEY}?fields=issuetype,summary,status")
    if s != 200:
        print(f"!! could not fetch {PARENT_KEY}: HTTP {s}")
        print(json.dumps(parent)[:500])
        return 1
    parent_type = parent.get("fields", {}).get("issuetype", {}).get("name", "")
    parent_summary = parent.get("fields", {}).get("summary", "")
    print(f"\nParent {PARENT_KEY}: type={parent_type}  summary={parent_summary[:80]}")

    can_subtask = parent_type in ("Epic", "Story", "Task")
    print(f"Strategy: {'Sub-task of ' + PARENT_KEY if can_subtask else 'Task linked to ' + PARENT_KEY}")

    # 4. File each draft.
    results = {}
    for fname in DRAFTS:
        path = DRAFTS_DIR / fname
        if not path.exists():
            print(f"\n!! missing draft: {path}")
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
        # Add helpful default labels
        for default in ("rw-onprem", "pr-7-followup"):
            if default not in labels:
                labels.append(default)

        if can_subtask and subtask_id:
            payload = {"fields": {
                "project": {"key": "INFRA"},
                "summary": title,
                "description": adf,
                "issuetype": {"id": subtask_id},
                "parent": {"key": PARENT_KEY},
                "labels": labels,
            }}
            kind_str = "Sub-task"
        else:
            # Fallback: file as Task and link to parent
            payload = {"fields": {
                "project": {"key": "INFRA"},
                "summary": title,
                "description": adf,
                "issuetype": {"id": task_id or story_id},
                "labels": labels,
            }}
            kind_str = "Task"

        if idris_id:
            payload["fields"]["assignee"] = {"accountId": idris_id}

        print(f"\n[POST {kind_str}] {title[:90]}")
        s, resp = api("POST", "/rest/api/3/issue", payload)
        print(f"  HTTP {s}")
        if s in (200, 201):
            new_key = resp.get("key")
            print(f"  CREATED {new_key}")
            results[fname] = {"status": "OK", "key": new_key, "type": kind_str}

            # If we couldn't sub-task, add a "relates to" link
            if not can_subtask:
                link_payload = {
                    "type": {"name": "Relates"},
                    "inwardIssue": {"key": new_key},
                    "outwardIssue": {"key": PARENT_KEY},
                }
                ls, lresp = api("POST", "/rest/api/3/issueLink", link_payload)
                print(f"  Link to {PARENT_KEY}: HTTP {ls}")
        else:
            print(f"  err: {json.dumps(resp)[:500]}")
            results[fname] = {"status": "FAIL", "err": resp}

    print("\n=== SUMMARY ===")
    for fname, r in results.items():
        print(f"  {r.get('status'):4}  {r.get('key', '-'):14}  {fname}")
    RESULTS.write_text(json.dumps(results, indent=2))
    print(f"\nResults: {RESULTS}")

    return 0 if all(r.get("status") == "OK" for r in results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""
Reconcile the standup-created tickets (INFRA-1589..1594) against what already
exists on INFRA board 322, per the 2026-07-13 review.

Actions:
  1. Close INFRA-1590 as Duplicate of INFRA-1586 (link + transition + comment).
  2. Link INFRA-1592 -> relates -> INFRA-1588 (Idris's Grafana/Freshservice).
  3. Keep INFRA-1593; link -> relates -> INFRA-1588 + comment "depends on".
  4. Link INFRA-1589 -> relates -> INFRA-1585; add 1589 to board 322 active sprint.
  5. Link INFRA-1591 -> relates -> INFRA-1559 (AAD identity epic).
  (No Done-moves: 1585 stays In Progress, 1584 held until its PR lands.)

DRY-RUN BY DEFAULT. Pass --go to execute.

Auth (WSL): export ATLASSIAN_TOKEN=...  (or CONFLUENCE_TOKEN= in scripts/push-to-confluence.sh)
"""
import base64, json, os, sys, urllib.error, urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
GO = "--go" in sys.argv
BASE = "https://usxpress.atlassian.net"
EMAIL = os.environ.get("JIRA_EMAIL", "doke@usxpress.com")
BOARD = 322

# link actions: (type, outward_key, inward_key)   [Duplicate: outward "duplicates" inward]
LINKS = [
    ("Duplicate", "INFRA-1590", "INFRA-1586"),
    ("Relates",   "INFRA-1592", "INFRA-1588"),
    ("Relates",   "INFRA-1593", "INFRA-1588"),
    ("Relates",   "INFRA-1589", "INFRA-1585"),
    ("Relates",   "INFRA-1591", "INFRA-1559"),
]
COMMENTS = {
    "INFRA-1593": "Depends on INFRA-1588 (Grafana <-> Freshservice alert integration). "
                  "This ticket is the concrete pod-crashloop alert riding on that integration.",
}
CLOSE_AS_DUP = ("INFRA-1590", "INFRA-1586")   # (issue, of)
SPRINT_ADD = ("INFRA-1589", BOARD)


def get_token():
    t = os.environ.get("ATLASSIAN_TOKEN") or os.environ.get("CONFLUENCE_TOKEN")
    if t:
        return t.strip()
    f = REPO / "scripts" / "push-to-confluence.sh"
    if f.exists():
        for ln in f.read_text().splitlines():
            if ln.strip().startswith("CONFLUENCE_TOKEN="):
                return ln.split("=", 1)[1].strip().strip('"').strip("'")
    sys.exit("No token: set ATLASSIAN_TOKEN (or CONFLUENCE_TOKEN in push-to-confluence.sh)")


AUTH = "Basic " + base64.b64encode(f"{EMAIL}:{get_token()}".encode()).decode()


def api(method, path, body=None, agile=False):
    url = BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": AUTH, "Accept": "application/json", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw[:400]}


def do_link(ltype, outward, inward):
    if not GO:
        print(f"[plan] link {outward} --{ltype}--> {inward}"); return
    s, r = api("POST", "/rest/api/3/issueLink", {
        "type": {"name": ltype}, "outwardIssue": {"key": outward}, "inwardIssue": {"key": inward}})
    print(f"  link {outward}/{inward} ({ltype}): {'OK' if s in (200,201) else f'FAIL {s} {r}'}")


def do_comment(issue, body):
    if not GO:
        print(f"[plan] comment on {issue}: {body[:60]}..."); return
    adf = {"type": "doc", "version": 1, "content": [
        {"type": "paragraph", "content": [{"type": "text", "text": body}]}]}
    s, r = api("POST", f"/rest/api/3/issue/{issue}/comment", {"body": adf})
    print(f"  comment {issue}: {'OK' if s in (200,201) else f'FAIL {s} {r}'}")


def close_dup(issue, of):
    if not GO:
        print(f"[plan] transition {issue} -> Done (resolution Duplicate), dup of {of}"); return
    s, tr = api("GET", f"/rest/api/3/issue/{issue}/transitions")
    target = None
    for t in tr.get("transitions", []):
        cat = (t.get("to", {}).get("statusCategory", {}) or {}).get("key")
        nm = t.get("name", "").lower()
        if cat == "done" or any(w in nm for w in ("done", "close", "resolve")):
            target = t; break
    if not target:
        print(f"  !! {issue}: no closing transition found ({[t.get('name') for t in tr.get('transitions',[])]})")
        return
    # try with resolution=Duplicate, fall back without
    for fields in ({"resolution": {"name": "Duplicate"}}, None):
        body = {"transition": {"id": target["id"]}}
        if fields:
            body["fields"] = fields
        s, r = api("POST", f"/rest/api/3/issue/{issue}/transitions", body)
        if s in (200, 204):
            print(f"  closed {issue} via '{target['name']}'"
                  f"{' (resolution Duplicate)' if fields else ' (no resolution field)'}")
            return
    print(f"  !! {issue} transition failed: {s} {r}")


def add_to_sprint(issue, board):
    if not GO:
        print(f"[plan] add {issue} to active sprint of board {board}"); return
    s, r = api("GET", f"/rest/agile/1.0/board/{board}/sprint?state=active")
    sprints = r.get("values", []) if s == 200 else []
    if not sprints:
        print(f"  !! no active sprint on board {board} (HTTP {s}) — add {issue} manually"); return
    sid = sprints[0]["id"]
    s, r = api("POST", f"/rest/agile/1.0/sprint/{sid}/issue", {"issues": [issue]})
    print(f"  add {issue} -> sprint {sid} ({sprints[0].get('name')}): "
          f"{'OK' if s in (200,204) else f'FAIL {s} {r}'}")


def main():
    print(f"{'EXECUTE' if GO else 'DRY-RUN'} — reconcile INFRA-1589..1594 @ {BASE} as {EMAIL}\n")
    print("Links:")
    for lt, o, i in LINKS:
        do_link(lt, o, i)
    print("\nClose duplicate:")
    close_dup(*CLOSE_AS_DUP)
    print("\nComments:")
    for iss, body in COMMENTS.items():
        do_comment(iss, body)
    print("\nSprint:")
    add_to_sprint(*SPRINT_ADD)
    print("\nDone." if GO else "\nDry-run only — re-run with --go to apply.")


if __name__ == "__main__":
    main()

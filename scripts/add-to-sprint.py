#!/usr/bin/env python3
"""
Add issues to the ACTIVE sprint of INFRA board 322.

Safe + idempotent: adding an issue already in the sprint is a no-op.
Does NOT touch links/comments/transitions (that's reconcile-tickets.py).

Default set = Idris's INFRA-1588 + the kept standup tickets (1589 already there,
included harmlessly; 1590 excluded — it's closed as a duplicate).

DRY-RUN BY DEFAULT. Pass --go to apply.
Override the set: pass keys as args, e.g. `... --go INFRA-1588 INFRA-1592`.

Auth (WSL): export ATLASSIAN_TOKEN=...
"""
import base64, json, os, sys, urllib.error, urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
GO = "--go" in sys.argv
BASE = "https://usxpress.atlassian.net"
EMAIL = os.environ.get("JIRA_EMAIL", "doke@usxpress.com")
BOARD = 322

DEFAULT_ISSUES = ["INFRA-1588", "INFRA-1589", "INFRA-1591", "INFRA-1592", "INFRA-1593", "INFRA-1594"]
args = [a for a in sys.argv[1:] if a.startswith("INFRA-")]
ISSUES = args or DEFAULT_ISSUES


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


def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method, headers={
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
            return e.code, {"raw": raw[:300]}


def main():
    print(f"{'EXECUTE' if GO else 'DRY-RUN'} — add to active sprint of board {BOARD} @ {BASE}")
    print(f"Issues: {', '.join(ISSUES)}\n")

    s, r = api("GET", f"/rest/agile/1.0/board/{BOARD}/sprint?state=active")
    sprints = r.get("values", []) if s == 200 else []
    if not sprints:
        sys.exit(f"No active sprint on board {BOARD} (HTTP {s} {r}).")
    sid, sname = sprints[0]["id"], sprints[0].get("name")
    print(f"Active sprint: {sid} '{sname}'\n")

    if not GO:
        for k in ISSUES:
            print(f"[plan] add {k} -> sprint {sid}")
        print("\nDry-run only — re-run with --go to apply.")
        return

    # Agile API accepts up to 50 issues in one call.
    s, r = api("POST", f"/rest/agile/1.0/sprint/{sid}/issue", {"issues": ISSUES})
    if s in (200, 204):
        print(f"OK — added {len(ISSUES)} issue(s) to sprint {sid}.")
    else:
        print(f"Batch add failed ({s} {r}); retrying individually:")
        for k in ISSUES:
            s2, r2 = api("POST", f"/rest/agile/1.0/sprint/{sid}/issue", {"issues": [k]})
            print(f"  {k}: {'OK' if s2 in (200,204) else f'FAIL {s2} {r2}'}")


if __name__ == "__main__":
    main()

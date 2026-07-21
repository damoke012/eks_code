#!/usr/bin/env python3
"""
Rename a sprint on INFRA board 322.

Fixes the duplicate "UI Sprint 1": renames the EARLIER one (1 Jul – 14 Jul)
to "UI Sprint 0" so the sequence reads 0 -> 1 -> 2.

Auth: export ATLASSIAN_TOKEN (Atlassian API token) before running.
      EMAIL defaults to doke@usxpress.com (override with JIRA_EMAIL).

DRY-RUN by default (just lists sprints). Pass --go to actually rename.

  export ATLASSIAN_TOKEN='...'          # do NOT paste the token into chat
  python3 scripts/rename-sprint.py       # dry-run: list all sprints on board 322
  python3 scripts/rename-sprint.py --go   # execute the rename
"""
import base64, json, os, sys, urllib.request, urllib.error

BASE  = "https://usxpress.atlassian.net"
EMAIL = os.environ.get("JIRA_EMAIL", "doke@usxpress.com")
BOARD = 322
GO    = "--go" in sys.argv

# Insert a Jul 15-30 sprint as "UI Sprint 2"; the two later FUTURE sprints
# shift up one more.  {sprintId: (expected_current_name, new_name)} — the
# expected_current is a safety guard; we refuse to rename on a mismatch.
TARGETS = {
    1041: ("UI Sprint 3", "UI Sprint 4"),
    959:  ("UI Sprint 2", "UI Sprint 3"),
}

# New sprint to create for the missing Jul 15-30 slot.
CREATE = {
    "name":      "UI Sprint 2",
    "startDate": "2026-07-15T00:00:00.000Z",
    "endDate":   "2026-07-30T23:59:00.000Z",
}


def get_token():
    t = os.environ.get("ATLASSIAN_TOKEN") or os.environ.get("CONFLUENCE_TOKEN")
    if not t:
        sys.exit("No token: export ATLASSIAN_TOKEN='<atlassian-api-token>' first.")
    return t.strip()


AUTH = "Basic " + base64.b64encode(f"{EMAIL}:{get_token()}".encode()).decode()


def api(method, path, body=None):
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
        headers={"Authorization": AUTH, "Accept": "application/json",
                 "Content-Type": "application/json"})
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


def list_sprints():
    out, start = [], 0
    while True:
        s, r = api("GET", f"/rest/agile/1.0/board/{BOARD}/sprint?startAt={start}&maxResults=50")
        if s != 200:
            sys.exit(f"list sprints failed: HTTP {s} {r}")
        out += r.get("values", [])
        if r.get("isLast", True):
            break
        start += len(r.get("values", []))
    return out


def main():
    print(f"{'EXECUTE' if GO else 'DRY-RUN'} @ {BASE}  board {BOARD}  as {EMAIL}\n")
    live = {sp.get("id"): sp for sp in list_sprints()}

    print(f"{'ID':>7}  {'STATE':8}  {'START':12}  NAME")
    for sid, sp in live.items():
        flag = ""
        if sid in TARGETS:
            flag = f"   <-- rename to '{TARGETS[sid][1]}'"
        print(f"{sid:>7}  {sp.get('state',''):8}  {(sp.get('startDate') or '')[:10]:12}  {sp.get('name','')}{flag}")
    print()

    for sid, (expected, new_name) in TARGETS.items():
        sp = live.get(sid)
        if not sp:
            print(f"  !! sprint {sid} not found on board — skip"); continue
        cur = sp.get("name", "")
        if cur == new_name:
            print(f"  = sprint {sid} already '{new_name}' — skip"); continue
        if cur != expected:
            print(f"  !! sprint {sid} is '{cur}', expected '{expected}' — SKIP (safety guard)"); continue
        if not GO:
            print(f"[plan] POST /rest/agile/1.0/sprint/{sid}  '{cur}' -> '{new_name}'"); continue
        # Partial update (POST) — only the name; dates/state untouched.
        s, r = api("POST", f"/rest/agile/1.0/sprint/{sid}", {"name": new_name})
        print(f"  {'OK' if s == 200 else f'FAIL {s} {r}'} — sprint {sid} '{cur}' -> "
              f"'{r.get('name', new_name) if s == 200 else new_name}'")

    # --- create the missing Jul 15-30 sprint (idempotent) ---
    print()
    dup = next((sp for sp in live.values()
                if sp.get("name") == CREATE["name"]
                and (sp.get("startDate") or "")[:10] == CREATE["startDate"][:10]), None)
    if dup:
        print(f"  = sprint '{CREATE['name']}' ({CREATE['startDate'][:10]}) already exists "
              f"(id {dup['id']}) — skip create")
    elif not GO:
        print(f"[plan] POST /rest/agile/1.0/sprint  create '{CREATE['name']}' "
              f"{CREATE['startDate'][:10]}..{CREATE['endDate'][:10]}  originBoardId={BOARD}")
    else:
        s, r = api("POST", "/rest/agile/1.0/sprint", {**CREATE, "originBoardId": BOARD})
        if s in (200, 201):
            print(f"  OK — created sprint {r.get('id')} '{r.get('name')}' "
                  f"{(r.get('startDate') or '')[:10]}..{(r.get('endDate') or '')[:10]} (state {r.get('state')})")
        else:
            print(f"  FAIL {s} — create '{CREATE['name']}': {r}")

    if not GO:
        print("\nRe-run with --go to execute.")


if __name__ == "__main__":
    main()

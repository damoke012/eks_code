#!/usr/bin/env python3
"""Find INFRA tickets that are ours but invisible on the sprint board, and fix it.

Two ways work disappears from a board, and both happened:

  A. NO SPRINT AT ALL. Tickets filed by script -- file-alert-delivery-tickets.py,
     decide-and-close-2026-08-21.py -- were created with a parent epic and never
     added to a sprint. They exist, they get worked, and the board does not show
     them. INFRA-1657 was closed today having never appeared on Sprint 3.
  B. OPEN, BUT PARKED IN A CLOSED SPRINT. Carried over in name only; the board
     filters on the active sprint, so nobody sees them either.

WHAT IT ADDS, and what it deliberately does not:
  * every OPEN ticket in either category -> active sprint;
  * a DONE ticket only if it was resolved DURING the active sprint. Work finished
    this sprint belongs to this sprint.
  * a DONE ticket resolved BEFORE the sprint started is listed and LEFT ALONE.
    Dragging June's finished work into Sprint 3 would make the sprint look like it
    delivered things it did not. Pass --include-old-done to override.

DRY-RUN BY DEFAULT. Pass --go.
Auth:  read -rsp 'Atlassian API token: ' ATLASSIAN_TOKEN; export ATLASSIAN_TOKEN; echo
"""
import importlib.util, os, sys, urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("closer", os.path.join(HERE, "close-sprint3-tickets.py"))
m = importlib.util.module_from_spec(spec)
_argv = sys.argv[:]; sys.argv = ["x"]
spec.loader.exec_module(m)
sys.argv = _argv

GO = "--go" in sys.argv
INCLUDE_OLD_DONE = "--include-old-done" in sys.argv
BOARD = 322

MINE = "(assignee = currentUser() OR reporter = currentUser())"
JQL_NO_SPRINT = f"project = INFRA AND sprint IS EMPTY AND {MINE} ORDER BY created ASC"
JQL_STRANDED = (f"project = INFRA AND sprint IS NOT EMPTY AND sprint NOT IN openSprints() "
                f"AND statusCategory != Done AND {MINE} ORDER BY created ASC")


def search(jql):
    """m.api returns a (status, json) TUPLE. Unpack it -- testing membership on
    the tuple is always False and silently reports 'no results'."""
    fields = "summary,status,assignee,created,resolutiondate"
    q = urllib.parse.urlencode({"jql": jql, "fields": fields, "maxResults": 100})
    tried = []
    for path in (f"/rest/api/3/search/jql?{q}", f"/rest/api/3/search?{q}"):
        try:
            status, body = m.api("GET", path)
        except Exception as e:                       # noqa: BLE001
            tried.append((path.split("?")[0], "exception", str(e)[:160])); continue
        if status == 200 and isinstance(body, dict) and "issues" in body:
            return body["issues"]
        detail = body.get("errorMessages") or body.get("raw") or body if isinstance(body, dict) else body
        tried.append((path.split("?")[0], status, str(detail)[:160]))
    print("!! search failed. Endpoints tried:", file=sys.stderr)
    for p, s, d in tried:
        print(f"     {p} -> {s} {d}", file=sys.stderr)
    print(f"   JQL: {jql}", file=sys.stderr)
    sys.exit(2)


def row(i):
    f = i["fields"]
    st = (f.get("status") or {}).get("name", "?")
    cat = ((f.get("status") or {}).get("statusCategory") or {}).get("key", "?")
    who = (f.get("assignee") or {}).get("displayName", "Unassigned")
    return {"key": i["key"], "summary": f.get("summary", "")[:64], "status": st,
            "done": cat == "done", "created": (f.get("created") or "")[:10],
            "resolved": (f.get("resolutiondate") or "")[:10], "who": who}


def main():
    print(f"== find-sprintless-tickets  [{'GO' if GO else 'DRY RUN'}]\n")
    m.preflight()

    s, r = m.api("GET", f"/rest/agile/1.0/board/{BOARD}/sprint?state=active")
    sprints = r.get("values", []) if s == 200 else []
    if not sprints:
        sys.exit(f"!! no active sprint on board {BOARD} (HTTP {s})")
    sid = sprints[0]["id"]
    sname = sprints[0].get("name", "?")
    sstart = (sprints[0].get("startDate") or "")[:10]
    print(f"Active sprint: {sid} '{sname}'  started {sstart or '(no start date)'}\n")

    rows, seen = [], set()
    for label, jql in (("no sprint", JQL_NO_SPRINT), ("stranded in a closed sprint", JQL_STRANDED)):
        found = [row(i) for i in search(jql)]
        for f in found:
            if f["key"] in seen:
                continue
            seen.add(f["key"]); f["why"] = label; rows.append(f)

    if not rows:
        print("Nothing missing from the board.")
        return 0

    add, skip = [], []
    for f in rows:
        if not f["done"]:
            add.append(f)
        elif sstart and f["resolved"] and f["resolved"] >= sstart:
            add.append(f)
        elif INCLUDE_OLD_DONE:
            add.append(f)
        else:
            skip.append(f)

    print(f"-- will ADD to '{sname}' ({len(add)}) " + "-" * 30)
    for f in add:
        tag = f"done {f['resolved']}" if f["done"] else f["status"]
        print(f"  {f['key']:<12} {tag:<16} {f['why']:<28} {f['summary']}")

    if skip:
        print(f"\n-- LEFT ALONE ({len(skip)}): finished before this sprint started " + "-" * 8)
        for f in skip:
            print(f"  {f['key']:<12} done {f['resolved']:<11} {f['summary']}")
        print("  (--include-old-done adds these too, at the cost of the sprint's honesty)")

    if not GO:
        print("\nDry run. Re-run with --go.")
        return 0

    keys = [f["key"] for f in add]
    for chunk in (keys[i:i + 50] for i in range(0, len(keys), 50)):
        s, r = m.api("POST", f"/rest/agile/1.0/sprint/{sid}/issue", {"issues": chunk})
        print(f"\n  add {len(chunk)}: {'OK' if s in (200, 204) else f'FAIL {s} {r}'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

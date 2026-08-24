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
# Sprintless is NOT the same as missing. 75 of the 89 found on the first real run
# were old backlog -- correctly unsprinted, and moving them would have tripled the
# sprint. The tickets that are actually invisible are the OPEN ones left behind in
# a closed sprint. --stranded-only restricts to those; it is the usual intent.
STRANDED_ONLY = "--stranded-only" in sys.argv

# Board 322 is the OLD board -- it has no active sprint, which is how the first
# run of this failed. Do not hardcode a board: enumerate every INFRA board and
# find the sprint. --sprint <id> pins it explicitly.
SPRINT_ARG = None
for _i, _a in enumerate(sys.argv):
    if _a == "--sprint" and _i + 1 < len(sys.argv):
        SPRINT_ARG = int(sys.argv[_i + 1])

MINE = "(assignee = currentUser() OR reporter = currentUser())"
JQL_NO_SPRINT = f"project = INFRA AND sprint IS EMPTY AND {MINE} ORDER BY created ASC"

# ⚠️ 2026-08-24. The previous version asked JQL
#     sprint IS NOT EMPTY AND sprint NOT IN openSprints()
# and reported 14 tickets "stranded in a closed sprint". They were not. `sprint`
# is a MULTI-VALUED field: an issue carried from Sprint 2 into Sprint 3 holds
# [6088, 959] and matches `NOT IN openSprints()` forever, because it still has a
# sprint that is not open. All 14 were already in Sprint 3 -- visible in the
# board UI at the time -- and adding them was a no-op the sprint count proved
# (34 before, 34 after).
#
# Membership is now computed as a DIFFERENCE against the sprint's own member
# list, read from the agile API, which is the only unambiguous source. No JQL
# predicate on `sprint` can answer "is this issue in sprint N" reliably.
JQL_OPEN_MINE = f"project = INFRA AND statusCategory != Done AND {MINE} ORDER BY created ASC"


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


def all_sprints():
    """Every sprint on every INFRA board, newest first. Boards that do not
    support sprints (kanban) return 400 -- skipped, not fatal."""
    s, r = m.api("GET", "/rest/agile/1.0/board?projectKeyOrId=INFRA&maxResults=50")
    boards = r.get("values", []) if s == 200 else []
    out = []
    for b in boards:
        bs, br = m.api("GET", f"/rest/agile/1.0/board/{b['id']}/sprint?maxResults=50")
        if bs != 200:
            continue
        for sp in br.get("values", []):
            sp["_board"] = f"{b['id']} {b.get('name','?')}"
            out.append(sp)
    out.sort(key=lambda x: x.get("startDate") or "", reverse=True)
    return out


def resolve_sprint():
    """Pick the sprint to add to. Explicit --sprint wins; otherwise the single
    active one; otherwise print what exists and refuse to guess."""
    sprints = all_sprints()
    if not sprints:
        print("!! no sprints found on any INFRA board", file=sys.stderr)
        return None
    if SPRINT_ARG:
        for sp in sprints:
            if sp["id"] == SPRINT_ARG:
                return sp
        print(f"!! sprint {SPRINT_ARG} not found on any INFRA board", file=sys.stderr)
        sprints_table(sprints)
        return None
    active = [sp for sp in sprints if sp.get("state") == "active"]
    if len(active) == 1:
        return active[0]
    print("!! cannot pick a sprint automatically "
          f"({len(active)} active). Re-run with --sprint <id>:", file=sys.stderr)
    sprints_table(sprints)
    return None


def sprints_table(sprints):
    print("\n  id     state      started     board / name", file=sys.stderr)
    for sp in sprints[:20]:
        print(f"  {sp['id']:<6} {sp.get('state','?'):<10} "
              f"{(sp.get('startDate') or '')[:10]:<11} "
              f"{sp['_board']} / {sp.get('name','?')}", file=sys.stderr)


def sprint_members(sid):
    """Keys currently in the sprint, from the agile API. The ONLY reliable
    answer to 'is this issue in sprint N' -- see the note on JQL_OPEN_MINE."""
    keys, start = set(), 0
    while True:
        q = urllib.parse.urlencode({"fields": "summary", "maxResults": 100, "startAt": start})
        s, body = m.api("GET", f"/rest/agile/1.0/sprint/{sid}/issue?{q}")
        if s != 200:
            print(f"!! could not read sprint {sid} membership (HTTP {s})", file=sys.stderr)
            sys.exit(2)
        issues = body.get("issues", [])
        keys.update(i["key"] for i in issues)
        start += len(issues)
        if start >= body.get("total", 0) or not issues:
            return keys


def main():
    print(f"== find-sprintless-tickets  [{'GO' if GO else 'DRY RUN'}]\n")
    m.preflight()

    target = resolve_sprint()
    if target is None:
        return 2
    sid = target["id"]
    sname = target.get("name", "?")
    sstart = (target.get("startDate") or "")[:10]
    print(f"Target sprint: {sid} '{sname}' [{target.get('state')}]  "
          f"started {sstart or '(no start date)'}\n")

    members = sprint_members(sid)
    print(f"sprint {sid} currently holds {len(members)} issues\n")

    sources = [("open, not in this sprint", JQL_OPEN_MINE)]
    if not STRANDED_ONLY:
        sources.insert(0, ("no sprint at all", JQL_NO_SPRINT))
    else:
        print("--stranded-only: ignoring never-sprinted backlog, which belongs in the backlog\n")

    rows, seen = [], set()
    for label, jql in sources:
        for f in (row(i) for i in search(jql)):
            if f["key"] in seen or f["key"] in members:
                continue                      # already in the target sprint
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

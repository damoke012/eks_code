#!/usr/bin/env python3
"""Everything in Jira still assigned to you, across every project.

READ ONLY. Makes no change of any kind — there is no --go.

Why not list-open-tickets.py: that one shows the whole on-prem BOARD (epic INFRA-1632
plus open sprints) regardless of assignee, so it answers "what is the team carrying",
not "what is left on me". It also scopes to project INFRA, which hides anything
assigned to you elsewhere.

Identity comes from /rest/api/3/myself, not from a name typed in here. That call is
also the token proof: Jira answers an unauthorised read with 404 "does not exist",
indistinguishable from an empty result, so an unproven token would make this script
print "nothing left" and be believed (see lint-jira-preflight.sh).

A ticket with no sprint does not appear on the board at all, so it is flagged here —
that is the class find-sprintless-tickets.py exists for.

    read -rsp 'Atlassian API token: ' ATLASSIAN_TOKEN; export ATLASSIAN_TOKEN; echo
    python3 scripts/list-my-tickets.py
    python3 scripts/list-my-tickets.py --all        # include Done
"""
import importlib.util, os, sys, urllib.parse

spec = importlib.util.spec_from_file_location(
    "closer", os.path.join(os.path.dirname(os.path.abspath(__file__)), "close-sprint3-tickets.py"))
m = importlib.util.module_from_spec(spec)
_argv = sys.argv[:]; sys.argv = ["x"]
spec.loader.exec_module(m)
sys.argv = _argv

SHOW_ALL = "--all" in sys.argv
SPRINT_FIELD = "customfield_10010"


def search(jql):
    """m.api returns a (status, json) TUPLE. Testing `"issues" in r` on the tuple is
    always False — that bug made the first list-open-tickets fall through both
    endpoints silently, then report an error it never had."""
    fields = f"summary,status,updated,created,project,labels,{SPRINT_FIELD}"
    out, start = [], 0
    while True:
        q = urllib.parse.urlencode(
            {"jql": jql, "fields": fields, "maxResults": 100, "startAt": start})
        tried, issues, total = [], None, 0
        for path in (f"/rest/api/3/search/jql?{q}", f"/rest/api/3/search?{q}"):
            try:
                status, body = m.api("GET", path)
            except Exception as e:                      # noqa: BLE001
                tried.append((path.split("?")[0], "exception", str(e)[:160])); continue
            if status == 200 and isinstance(body, dict) and "issues" in body:
                issues, total = body["issues"], body.get("total", 0)
                break
            detail = (body.get("errorMessages") or body.get("raw") or body
                      if isinstance(body, dict) else body)
            tried.append((path.split("?")[0], status, str(detail)[:160]))
        if issues is None:
            print("!! could not search Jira. Endpoints tried:", file=sys.stderr)
            for p, s, d in tried:
                print(f"     {p}  ->  {s}  {d}", file=sys.stderr)
            print(f"   JQL was: {jql}", file=sys.stderr)
            sys.exit(2)
        out.extend(issues)
        start += len(issues)
        if not issues or start >= total:
            return out


def sprint_of(f):
    v = f.get(SPRINT_FIELD)
    if not v:
        return ""
    if isinstance(v, list):
        names = [s.get("name", "?") if isinstance(s, dict) else str(s) for s in v]
        return names[-1] if names else ""
    return str(v)[:24]


def main():
    print("== list-my-tickets  [READ ONLY]\n")

    status, me = m.api("GET", "/rest/api/3/myself")
    if status != 200 or not isinstance(me, dict) or not me.get("accountId"):
        print(f"!! token NOT PROVEN: /myself returned {status} {str(me)[:200]}", file=sys.stderr)
        print("   Every result below would be unreliable, so nothing was read.", file=sys.stderr)
        sys.exit(2)
    print(f"authenticated as: {me.get('displayName')} <{me.get('emailAddress')}>")
    print(f"accountId       : {me['accountId']}\n")

    jql = "assignee = currentUser()"
    if not SHOW_ALL:
        jql += " AND statusCategory != Done"
    jql += " ORDER BY status ASC, key ASC"
    print(f"JQL: {jql}\n")

    issues = search(jql)
    rows = []
    for i in issues:
        f = i["fields"]
        rows.append((
            i["key"],
            (f.get("status") or {}).get("name", "?"),
            ((f.get("status") or {}).get("statusCategory") or {}).get("name", "?"),
            (f.get("project") or {}).get("key", "?"),
            f.get("updated", "")[:10],
            sprint_of(f),
            f.get("summary", ""),
        ))

    if not rows:
        print("nothing assigned to you is open. Token was PROVEN above, so this is a")
        print("real empty result, not an auth failure.")
        return

    by_cat = {}
    for r in rows:
        by_cat.setdefault(r[2], []).append(r)

    for cat in ("In Progress", "To Do", "Done"):
        rs = by_cat.pop(cat, [])
        if not rs:
            continue
        print(f"-- {cat} ({len(rs)}) --")
        for k, st, _c, pj, upd, sp, s in sorted(rs, key=lambda r: r[0]):
            flag = "" if sp else "  [NO SPRINT - off the board]"
            print(f"  {k:<12} {st:<14} {pj:<6} {upd}  {sp[:18]:<18} {s[:64]}{flag}")
        print()
    for cat, rs in by_cat.items():
        print(f"-- {cat} ({len(rs)}) --")
        for k, st, _c, pj, upd, sp, s in sorted(rs, key=lambda r: r[0]):
            print(f"  {k:<12} {st:<14} {pj:<6} {upd}  {sp[:18]:<18} {s[:64]}")
        print()

    nosprint = [r for r in rows if not r[5] and r[2] != "Done"]
    print(f"total assigned to you: {len(rows)}")
    if nosprint:
        print(f"off the board (no sprint): {len(nosprint)} -> {', '.join(r[0] for r in nosprint)}")


if __name__ == "__main__":
    main()

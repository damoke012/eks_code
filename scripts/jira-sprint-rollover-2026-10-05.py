#!/usr/bin/env python3
"""Close the current INFRA sprint, close what is done, carry the rest into a new sprint.

Different from `jira-sprint-rollover-2026-09-21.py` in one important way: incomplete
issues go into the NEW SPRINT, not the backlog. That script was a reset; this one is a
rollover. It also creates no tickets.

  1. close every issue in the sprint whose status is already in the Done category
  2. create the next sprint
  3. move every issue that is NOT done into it
  4. close the old sprint

DRY-RUN BY DEFAULT. Pass --go to write. Pass --list for the read-only board survey.
Auth:  read -rsp 'Atlassian API token: ' ATLASSIAN_TOKEN; export ATLASSIAN_TOKEN; echo

ORDER MATTERS, and not for the obvious reason. Jira's own "complete sprint" dialog asks
where the incomplete issues should go; the API close does not ask and its default is not
worth discovering on a live board. So the issues are moved out EXPLICITLY, into a sprint
that already exists, before the close runs.

"Close the done ones" is best-effort by design. The INFRA workflow may have no transition
to a terminal status from where an issue currently sits, and a rollover should not fail
because one ticket is in an awkward state. Every skip is named.
"""
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request

GO = "--go" in sys.argv
LIST = "--list" in sys.argv

BASE = "https://usxpress.atlassian.net"
EMAIL = os.environ.get("JIRA_EMAIL", "doke@usxpress.com")
PROJECT = "INFRA"
BOARD = int(os.environ.get("JIRA_BOARD", "322"))

# Editable. Printed in the dry run so a wrong date is caught before the sprint exists.
SPRINT_START = "2026-10-05T13:00:00.000Z"   # Mon 05 Oct, 09:00 America/New_York (EDT)
SPRINT_END = "2026-10-16T21:00:00.000Z"     # Fri 16 Oct, 17:00 America/New_York (EDT)

# Status names that count as "closed enough" -- an issue already sitting in one of these
# is left alone rather than transitioned again.
TERMINAL = {"closed", "done", "resolved", "complete", "completed"}


def die(msg):
    sys.exit(f"\n!! {msg}\n")


def get_token():
    t = os.environ.get("ATLASSIAN_TOKEN") or os.environ.get("CONFLUENCE_TOKEN")
    if not t:
        die("No token. Set it without putting it in shell history:\n"
            "   read -rsp 'Atlassian API token: ' ATLASSIAN_TOKEN; export ATLASSIAN_TOKEN; echo")
    return t.strip()


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
            return e.code, {"raw": raw[:400]}


def preflight():
    """Prove the token works before any mutation.

    Jira answers an unauthenticated issue read with 404 and an unauthenticated create with
    400 -- both read as permission problems rather than auth ones, which has cost a whole
    --go run before now."""
    s, r = api("GET", "/rest/api/3/myself")
    if s != 200:
        tok = os.environ.get("ATLASSIAN_TOKEN", "")
        print(f"!! cannot authenticate to {BASE} as {EMAIL}  (HTTP {s})")
        if len(tok) < 20:
            print(f"   ATLASSIAN_TOKEN is {len(tok)} characters -- that is not a token.")
        else:
            print("   Plausible length, so expired or revoked.")
            print("   Mint one: https://id.atlassian.com/manage-profile/security/api-tokens")
        sys.exit(1)
    print(f"authenticated as {r.get('displayName')} <{r.get('emailAddress', EMAIL)}>\n")


def all_sprints():
    rows, start = [], 0
    while True:
        s, r = api("GET", f"/rest/agile/1.0/board/{BOARD}/sprint?startAt={start}&maxResults=50")
        if s != 200:
            die(f"cannot list sprints on board {BOARD} (HTTP {s}): {r}")
        rows.extend(r.get("values", []))
        if r.get("isLast", True):
            break
        start += len(r.get("values", []))
    return rows


def pick_sprint():
    """The sprint to close. Active if there is one, otherwise the one future sprint with issues.

    Board 322 has never had a sprint STARTED -- sprints go `future` -> `closed`, so `active`
    is permanently empty. Selection refuses to guess: exactly one active, or exactly one
    future sprint that HAS issues. An empty future sprint is a placeholder someone created
    and is never the answer.
    """
    override = None
    for i, a in enumerate(sys.argv):
        if a == "--sprint" and i + 1 < len(sys.argv):
            override = int(sys.argv[i + 1])
    rows = all_sprints()

    if override:
        hit = [x for x in rows if x["id"] == override]
        if not hit:
            die(f"--sprint {override} is not a sprint on board {BOARD}")
        return hit[0]

    active = [x for x in rows if x.get("state") == "active"]
    if len(active) == 1:
        return active[0]
    if len(active) > 1:
        die(f"{len(active)} active sprints: {[x['name'] for x in active]} -- pass --sprint <id>")

    future = []
    for x in rows:
        if x.get("state") != "future":
            continue
        s2, c = api("GET", f"/rest/agile/1.0/sprint/{x['id']}/issue?maxResults=0")
        if s2 == 200 and c.get("total", 0) > 0:
            x["_issues"] = c["total"]
            future.append(x)
    if len(future) == 1:
        f = future[0]
        print(f"no ACTIVE sprint; using the one future sprint that has issues: "
              f"{f['name']} ({f['_issues']})")
        return f
    die(f"no active sprint and {len(future)} future sprints with issues "
        f"{[x['name'] for x in future]} -- pass --sprint <id>, or --list to see them all")


def sprint_issues(sid):
    issues, start = [], 0
    while True:
        s, r = api("GET", f"/rest/agile/1.0/sprint/{sid}/issue"
                          f"?startAt={start}&maxResults=100&fields=summary,status,assignee")
        if s != 200:
            die(f"cannot read sprint {sid} issues (HTTP {s}): {r}")
        issues.extend(r.get("issues", []))
        start += len(r.get("issues", []))
        if start >= r.get("total", 0) or not r.get("issues"):
            break
    return issues


def status_of(issue):
    st = issue["fields"].get("status") or {}
    return st.get("name", "?"), (st.get("statusCategory") or {}).get("key")


def closing_transition(key):
    """A transition into a terminal status, or None.

    Returns (id, name). Looked up per issue rather than assumed: the INFRA workflow does
    not offer the same transitions from every status, and a hardcoded transition id is how
    a rollover half-finishes.
    """
    s, r = api("GET", f"/rest/api/3/issue/{key}/transitions")
    if s != 200:
        return None, f"cannot read transitions (HTTP {s})"
    for t in r.get("transitions", []):
        to = t.get("to") or {}
        cat = (to.get("statusCategory") or {}).get("key")
        if cat == "done" and (to.get("name", "").lower() in TERMINAL):
            return (t["id"], to.get("name")), None
    names = [((t.get("to") or {}).get("name")) for t in r.get("transitions", [])]
    return None, f"no terminal transition available (offers: {names})"


def close_sprint(sprint):
    """Close it, starting it first if it was never started.

    The API will not close a `future` sprint. Starting it and closing it preserves the
    sprint report and the completed-issue history; deleting it would not."""
    sid, name, state = sprint["id"], sprint["name"], sprint.get("state")
    if state == "future":
        s, r = api("POST", f"/rest/agile/1.0/sprint/{sid}", {"state": "active"})
        if s not in (200, 204):
            die(f"could not START {name} before closing it (HTTP {s}): {r}\n"
                f"   The carry-over already ran -- check the board before retrying.")
        print(f"   started {name} (it had never been started)")
    s, r = api("POST", f"/rest/agile/1.0/sprint/{sid}", {"state": "closed"})
    if s not in (200, 204):
        die(f"could not close {name} (HTTP {s}): {r}\n"
            f"   The carry-over already ran -- check the board before retrying.")
    print(f"   closed {name}")


def next_sprint_name(current):
    """Follow the board's own naming. 'UI Sprint 5' -> 'UI Sprint 6'."""
    m = re.match(r"^(.*?)(\d+)\s*$", current or "")
    if m:
        return f"{m.group(1)}{int(m.group(2)) + 1}"
    return f"Sprint from {SPRINT_START[:10]}"


def survey():
    print(f"-- sprints on board {BOARD} --")
    for x in all_sprints():
        s, c = api("GET", f"/rest/agile/1.0/sprint/{x['id']}/issue?maxResults=0")
        n = c.get("total", "?") if s == 200 else "?"
        print(f"   {x['id']:<6} {x.get('state','?'):<8} {n:>4} issue(s)  {x.get('name')}"
              f"   {str(x.get('startDate'))[:10]} -> {str(x.get('endDate'))[:10]}")


def main():
    if LIST:
        print("== jira board survey  [READ ONLY]\n")
        preflight()
        survey()
        return

    print(f"== jira sprint rollover  [{'EXECUTING' if GO else 'DRY RUN -- pass --go to execute'}]\n")
    preflight()

    sprint = pick_sprint()
    sid, sname = sprint["id"], sprint["name"]
    print(f"closing: {sname}  (id {sid}, state {sprint.get('state')})")

    issues = sprint_issues(sid)
    done, todo = [], []
    for i in issues:
        _, cat = status_of(i)
        (done if cat == "done" else todo).append(i)

    print(f"  {len(issues)} issue(s): {len(done)} done, {len(todo)} carrying over\n")

    print("-- CLOSING (already done) --")
    for i in done:
        name, _ = status_of(i)
        mark = "already terminal" if name.lower() in TERMINAL else "-> Closed"
        print(f"   {i['key']:<12} [{name:<12}] {mark:<16} {i['fields']['summary'][:48]}")

    new_name = next_sprint_name(sname)
    print(f"\n-- CARRYING OVER into {new_name} (not done) --")
    for i in todo:
        name, _ = status_of(i)
        who = ((i["fields"].get("assignee") or {}) or {}).get("displayName", "unassigned")
        print(f"   {i['key']:<12} [{name:<12}] {who[:18]:<18} {i['fields']['summary'][:44]}")

    print("\n-- then --")
    print(f"   create {new_name}   {SPRINT_START[:10]} -> {SPRINT_END[:10]}")
    print(f"   move   {len(todo)} issue(s) into it")
    if sprint.get("state") == "future":
        print(f"   start  {sname} -- it was never started, and a future sprint cannot be closed")
    print(f"   close  {sname} (id {sid})")

    if not GO:
        print("\ndry run -- nothing written. Read both lists above, then pass --go.")
        return

    # ---------------------------------------------------------------- execute --
    print("\n-- closing done issues --")
    for i in done:
        name, _ = status_of(i)
        if name.lower() in TERMINAL:
            print(f"   {i['key']:<12} already {name}")
            continue
        t, why = closing_transition(i["key"])
        if not t:
            print(f"   {i['key']:<12} SKIPPED -- {why}")
            continue
        tid, tname = t
        s, r = api("POST", f"/rest/api/3/issue/{i['key']}/transitions", {"transition": {"id": tid}})
        print(f"   {i['key']:<12} {'-> ' + tname if s in (200, 204) else f'FAIL {s} {r}'}")

    print("\n-- creating sprint --")
    s, r = api("POST", "/rest/agile/1.0/sprint", {
        "name": new_name, "startDate": SPRINT_START, "endDate": SPRINT_END,
        "originBoardId": BOARD})
    if s not in (200, 201):
        die(f"could not create sprint (HTTP {s}): {r}")
    new_id = r["id"]
    print(f"   created {new_name} (id {new_id})")

    print("\n-- carrying issues over --")
    keys = [i["key"] for i in todo]
    for chunk in [keys[n:n + 50] for n in range(0, len(keys), 50)]:
        s, r = api("POST", f"/rest/agile/1.0/sprint/{new_id}/issue", {"issues": chunk})
        if s not in (200, 204):
            die(f"could not move {len(chunk)} issue(s) into {new_name} (HTTP {s}): {r}\n"
                f"   {new_name} (id {new_id}) EXISTS and {sname} is still open -- "
                f"fix the move, then re-run with --sprint {sid}.")
        print(f"   {len(chunk)} issue(s): OK")

    print("\n-- closing old sprint --")
    close_sprint(sprint)

    print(f"\ndone. {new_name}: {BASE}/jira/software/c/projects/{PROJECT}/boards/{BOARD}")


if __name__ == "__main__":
    main()

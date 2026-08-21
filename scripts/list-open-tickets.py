#!/usr/bin/env python3
"""List the current state of the on-prem sprint board, straight from Jira.

READ ONLY. Makes no change of any kind — there is no --go.

Written because deciding what to close from wip/onprem-app-cicd/SPRINT-*.md is
deciding from a snapshot: that file was last accurate on 2026-08-20, and tickets
have been filed, closed and re-scoped since. Read the board, not the note.

    read -rsp 'Atlassian API token: ' ATLASSIAN_TOKEN; export ATLASSIAN_TOKEN; echo
    python3 scripts/list-open-tickets.py
    python3 scripts/list-open-tickets.py --all      # include Done
"""
import importlib.util, os, sys, urllib.parse

spec = importlib.util.spec_from_file_location(
    "closer", os.path.join(os.path.dirname(os.path.abspath(__file__)), "close-sprint3-tickets.py"))
m = importlib.util.module_from_spec(spec)
_argv = sys.argv[:]; sys.argv = ["x"]
spec.loader.exec_module(m)
sys.argv = _argv

SHOW_ALL = "--all" in sys.argv
EPIC = getattr(m, "EPIC", "INFRA-1632")

JQL = (f'project = INFRA AND (parent = {EPIC} OR sprint in openSprints()) '
       f'ORDER BY status ASC, key ASC')


def search(jql):
    """Try the current search endpoint, fall back to the classic one."""
    fields = "summary,status,assignee,updated,labels"
    q = urllib.parse.urlencode({"jql": jql, "fields": fields, "maxResults": 100})
    for path in (f"/rest/api/3/search/jql?{q}", f"/rest/api/3/search?{q}"):
        try:
            r = m.api("GET", path)
            if r and "issues" in r:
                return r["issues"]
        except Exception as e:              # noqa: BLE001 - either endpoint may be gone
            last = e
    print(f"!! could not search Jira: {last}", file=sys.stderr)
    sys.exit(2)


def main():
    print("== list-open-tickets  [READ ONLY]\n")
    m.preflight()
    issues = search(JQL)

    rows = []
    for i in issues:
        f = i["fields"]
        st = (f.get("status") or {}).get("name", "?")
        who = ((f.get("assignee") or {}) or {}).get("displayName") or "unassigned"
        rows.append((i["key"], st, who, f.get("updated", "")[:10], f.get("summary", "")))

    done = [r for r in rows if r[1].lower() in ("done", "closed", "resolved")]
    open_ = [r for r in rows if r not in done]

    def show(title, rs):
        print(f"-- {title} ({len(rs)}) --")
        for k, st, who, upd, s in rs:
            print(f"  {k:<12} {st:<14} {upd}  {who[:18]:<18} {s[:72]}")
        print()

    show("OPEN", sorted(open_, key=lambda r: r[0]))
    if SHOW_ALL:
        show("DONE", sorted(done, key=lambda r: r[0]))
    else:
        print(f"({len(done)} Done — pass --all to list them)")


if __name__ == "__main__":
    main()

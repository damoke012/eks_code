#!/usr/bin/env python3
"""Print the raw Sprint field of specific issues. READ ONLY.

Three different queries have now disagreed about where INFRA-1658 and friends
live: `sprint IS EMPTY` says they have one, sprint 959's member list says it is
not 959, and sprint 6155 is empty. Rather than infer from a fourth predicate,
read the field.

Resolves the Sprint custom-field id by name -- it differs per Jira instance and
hardcoding customfield_10020 is a guess.

    scripts/show-issue-sprints.py INFRA-1658 INFRA-1659 INFRA-1660 INFRA-1655
"""
import importlib.util, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("closer", os.path.join(HERE, "close-sprint3-tickets.py"))
m = importlib.util.module_from_spec(spec)
_argv = sys.argv[:]; sys.argv = ["x"]
spec.loader.exec_module(m)
sys.argv = _argv

KEYS = [a for a in sys.argv[1:] if a.startswith("INFRA-")]
if not KEYS:
    sys.exit("usage: show-issue-sprints.py INFRA-nnn [INFRA-nnn ...]")


def sprint_field_id():
    s, body = m.api("GET", "/rest/api/3/field")
    if s != 200:
        sys.exit(f"!! could not list fields (HTTP {s})")
    for f in body:
        if f.get("name") == "Sprint":
            return f["id"]
    sys.exit("!! no field named 'Sprint' on this instance")


def main():
    m.preflight()
    fid = sprint_field_id()
    print(f"Sprint field: {fid}\n")
    for k in KEYS:
        s, body = m.api("GET", f"/rest/api/3/issue/{k}?fields=summary,{fid}")
        if s != 200:
            print(f"  {k}: HTTP {s}")
            continue
        f = body.get("fields", {})
        val = f.get(fid)
        print(f"  {k}  {f.get('summary','')[:56]}")
        if not val:
            print("     sprint: (none)")
            continue
        for sp in val:
            if isinstance(sp, dict):
                print(f"     sprint: {sp.get('id')} '{sp.get('name')}' [{sp.get('state')}]"
                      f" board {sp.get('boardId')}")
            else:
                print(f"     sprint (raw): {str(sp)[:160]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

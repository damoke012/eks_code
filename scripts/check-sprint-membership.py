#!/usr/bin/env python3
"""Ask a sprint what it contains. READ ONLY -- there is no --go.

Written because find-sprintless-tickets.py could not tell a failed write from a
stale query. An issue's `sprint` field is a LIST: adding it to a new sprint does
not remove the closed one, so `sprint NOT IN openSprints()` keeps matching it
either way. That check cannot distinguish "the add failed" from "the add worked".
This one can, because it asks the sprint for its members rather than asking the
issues for their sprints.

    scripts/check-sprint-membership.py 959
    scripts/check-sprint-membership.py 959 INFRA-1638 INFRA-1642
"""
import importlib.util, os, sys, urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("closer", os.path.join(HERE, "close-sprint3-tickets.py"))
m = importlib.util.module_from_spec(spec)
_argv = sys.argv[:]; sys.argv = ["x"]
spec.loader.exec_module(m)
sys.argv = _argv

nums = [a for a in sys.argv[1:] if a.isdigit()]
want = [a for a in sys.argv[1:] if a.startswith("INFRA-")]
if not nums:
    sys.exit("usage: check-sprint-membership.py <sprint-id> [INFRA-nnn ...]")
SID = int(nums[0])


def main():
    m.preflight()
    keys, start = [], 0
    while True:
        q = urllib.parse.urlencode({"fields": "summary,status", "maxResults": 100, "startAt": start})
        s, body = m.api("GET", f"/rest/agile/1.0/sprint/{SID}/issue?{q}")
        if s != 200:
            sys.exit(f"!! sprint {SID}: HTTP {s} {body}")
        issues = body.get("issues", [])
        keys.extend(i["key"] for i in issues)
        start += len(issues)
        if start >= body.get("total", 0) or not issues:
            break

    print(f"sprint {SID} contains {len(keys)} issues\n")
    if not want:
        for k in sorted(keys, key=lambda x: int(x.split("-")[1])):
            print(f"  {k}")
        return 0

    missing = [k for k in want if k not in keys]
    for k in want:
        print(f"  {k}: {'PRESENT' if k in keys else 'ABSENT'}")
    if missing:
        print(f"\n!! {len(missing)} of {len(want)} are NOT in sprint {SID} -- the write did not apply")
        return 1
    print(f"\nAll {len(want)} present. The add applied; any query still listing them is stale.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

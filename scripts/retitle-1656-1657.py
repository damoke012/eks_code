#!/usr/bin/env python3
"""Make two closed tickets' titles match what they turned out to be.

Both were closed with a comment that corrects the record, and in both cases the
SUMMARY still states the original, wrong thing -- which is the field that shows
on a board, in search, and in every link. A correction only the comment carries
is a correction most people will never see.

  INFRA-1657  "Scrape flux-system..." -- that was the first of four defects, and
              the close comment says "re-scoped in place" while the title was
              never actually re-scoped.
  INFRA-1656  "...auto-merges on green..." -- false. allow_auto_merge is false at
              the repo level; #109 was merged by hand by dare-x.

DRY-RUN BY DEFAULT. Pass --go.
Auth:  read -rsp 'Atlassian API token: ' ATLASSIAN_TOKEN; export ATLASSIAN_TOKEN; echo
"""
import importlib.util, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("closer", os.path.join(HERE, "close-sprint3-tickets.py"))
m = importlib.util.module_from_spec(spec)
_argv = sys.argv[:]; sys.argv = ["x"]
spec.loader.exec_module(m)
sys.argv = _argv
GO = "--go" in sys.argv

RETITLE = {
    "INFRA-1657": "Make the Flux alert rules able to fire at all (no scrape, missing metric, "
                  "wrong matcher, churning labels)",
    "INFRA-1656": "op-prod merge gate on iaac-talos-flux-platform -- filed on a wrong auto-merge "
                  "premise, see correction",
}


def main():
    print(f"== retitle  [{'GO' if GO else 'DRY RUN'}]\n")
    m.preflight()
    for key, new in RETITLE.items():
        s, body = m.api("GET", f"/rest/api/3/issue/{key}?fields=summary")
        if s != 200:
            print(f"  !! {key}: could not read (HTTP {s})")
            continue
        cur = body.get("fields", {}).get("summary", "")
        if cur == new:
            print(f"  {key}: already correct")
            continue
        print(f"  {key}")
        print(f"    was: {cur}")
        print(f"    now: {new}")
        if not GO:
            continue
        s, r = m.api("PUT", f"/rest/api/3/issue/{key}", {"fields": {"summary": new}})
        print(f"    {'OK' if s in (200, 204) else f'FAIL {s} {r}'}")
    if not GO:
        print("\nDry run. Re-run with --go.")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Give prod its own approval environment, separate from dev and qa.

Today the `approve` job names ONE environment, `pipeline-approval`, whatever the branch.
So dev, qa and prod share a reviewer list and a self-review setting: prod can never be
stricter than dev. Doke's call 2026-09-15 -- prod needs different rules.

After this, the environment name is derived the same way everything else is:

    prod        -> pipeline-approval-prod   (own reviewers, prevent_self_review: true)
    dev and qa  -> pipeline-approval        (raiser may self-approve, interim posture)

The expression form keeps one job rather than branching into two, so there is no path
where a run skips approval because it matched neither case.

    python3 scripts/patch-rw-pipeline-prod-approval.py /tmp/risingwave-pipeline
"""
import subprocess
import sys
from pathlib import Path

if len(sys.argv) != 2:
    sys.exit(__doc__)
repo = Path(sys.argv[1])
wf = repo / ".github/workflows/pipeline.yaml"
if not wf.exists():
    sys.exit(f"ERROR: no {wf} -- is {repo} a risingwave-pipeline clone?")

text = wf.read_text()

OLD = "    environment: pipeline-approval   # ← pauses here until a reviewer approves\n"
NEW = (
    "    # prod gets its OWN approval environment. One environment for all three tiers meant\n"
    "    # prod could never have stricter reviewers than dev -- the reviewer list and the\n"
    "    # prevent_self_review flag are properties of the ENVIRONMENT, not of the job.\n"
    "    #\n"
    "    #   prod       -> pipeline-approval-prod  (own reviewers, prevent_self_review: true)\n"
    "    #   dev, qa    -> pipeline-approval       (raiser may self-approve, interim posture)\n"
    "    #\n"
    "    # Kept as one job with an expression rather than two conditional jobs, so there is no\n"
    "    # path where a run matches neither and skips approval entirely.\n"
    "    environment: ${{ needs.validate.outputs.environment == 'prod'"
    " && 'pipeline-approval-prod' || 'pipeline-approval' }}\n"
)

n = text.count(OLD)
if n != 1:
    sys.exit(f"ERROR: expected exactly 1 `environment: pipeline-approval` line in approve, "
             f"found {n}.\n       Read {wf} before patching.")
wf.write_text(text.replace(OLD, NEW))
print(f"patched {wf}\n")
subprocess.run(["git", "-C", str(repo), "--no-pager", "diff"], check=False)
print("\nCreate pipeline-approval-prod BEFORE merging, or a prod run will fail to find it.")

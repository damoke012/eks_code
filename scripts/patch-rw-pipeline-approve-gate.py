#!/usr/bin/env python3
"""Skip the approval job too when there is nothing to apply.

Follow-up to the empty-change-set fix, which gated `execute` but not `approve`. A change
touching only pipelines/README.md therefore still parked the run on a required reviewer,
for a run that was going to apply nothing.

That matters beyond tidiness. A gate that asks for approvals it does not need trains people
to click without reading, and a queue of no-op approvals is how a real one gets waved
through. Nothing to apply means nothing to approve.

`execute` declares `needs: [validate, approve]`, and a job whose dependency was SKIPPED is
itself skipped -- so gating approve keeps execute skipped as well, without relying on two
conditions agreeing with each other.

    python3 scripts/patch-rw-pipeline-approve-gate.py /tmp/risingwave-pipeline
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

OLD = """  approve:
    needs: validate
    runs-on: ubuntu-latest
"""
NEW = """  approve:
    needs: validate
    runs-on: ubuntu-latest

    # Nothing to apply means nothing to approve. Without this, a change touching only
    # pipelines/README.md parks the run on a required reviewer for a deploy that will not
    # happen. Approvals that are not needed train people to click without reading, and that
    # is how the approvals that ARE needed get waved through.
    if: needs.validate.outputs.changed_count != '0'
"""

# IDEMPOTENCY. NEW begins with the same three lines as OLD, so the anchor still matches
# after a successful run and a second invocation applies the block AGAIN -- producing
# duplicate `if:` keys, which is invalid YAML and breaks the workflow. That happened on
# 2026-09-15 when a failed `git checkout -b` left a patched working tree behind and the
# next attempt re-applied on top. Refuse when the marker is already present.
if "changed_count != '0'" in text.split("  execute:")[0].split("  approve:")[-1]:
    sys.exit("ERROR: the approve job already has the changed_count gate. Nothing to do.\n"
             "       If the file looks wrong, reset it: git checkout -- "
             ".github/workflows/pipeline.yaml")

n = text.count(OLD)
if n != 1:
    sys.exit(f"ERROR: expected exactly 1 approve job header, found {n}.\n"
             f"       Read {wf} before patching.")
wf.write_text(text.replace(OLD, NEW))
print(f"patched {wf}\n")
subprocess.run(["git", "-C", str(repo), "--no-pager", "diff"], check=False)

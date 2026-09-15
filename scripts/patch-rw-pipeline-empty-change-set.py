#!/usr/bin/env python3
"""Stop an empty change set from looking like a successful deploy.

Two distinct faults, one symptom.

1. FAIL-OPEN DETECTION. The changed-files step ends every branch with `|| true`:

       CHANGED_FILES=$(git diff --name-only "$BEFORE" "$AFTER" | grep -E ... || true)

   so a `git diff` that FAILS -- empty `github.event.before`, a force-push, a shallow clone,
   a base commit not in the checkout -- yields an empty list rather than an error. "I could
   not determine what changed" then becomes "nothing changed", and the run goes green.

2. AN EMPTY SET STILL RUNS EXECUTE. With no files, execute still pulled credentials,
   installed psql, SKIPPED both apply steps, and reported success. On 2026-09-15 that exact
   shape was used as proof the pipeline worked; it proved only that the steps BEFORE the
   apply worked. A run that applies nothing must not look like a run that deployed.

Fixes, in that order: a check that fails CLOSED when detection could not have run, and an
`if:` that skips execute entirely when the count is zero -- visibly different in the UI and
in the API, rather than a green job with two dashes in the middle.

    python3 scripts/patch-rw-pipeline-empty-change-set.py /tmp/risingwave-pipeline
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

# ---- A: expose the count as a job output -------------------------------------------
OUT_OLD = "      rw_ns: ${{ steps.env-detect.outputs.rw_ns }}\n"
OUT_NEW = ("      rw_ns: ${{ steps.env-detect.outputs.rw_ns }}\n"
           "      changed_count: ${{ steps.detect-check.outputs.count }}\n")

# ---- B: the fail-closed detection check ---------------------------------------------
GUARD_ANCHOR = "      # Fixtures create objects."
DETECT_STEP = '''      # The step above ends every branch with `|| true`, so a git diff that FAILS produces
      # an EMPTY list instead of an error -- and an empty list reads as "nothing to apply",
      # which reports SUCCESS. A run that could not work out what changed is then
      # indistinguishable from a run that correctly found nothing. Fail closed.
      - name: Verify change detection ran
        id: detect-check
        shell: bash
        run: |
          BEFORE="${{ github.event.before }}"
          if [[ -z "$BEFORE" ]]; then
            echo "::error::github.event.before is empty, so the diff in the previous step"
            echo "::error::cannot have run. Refusing rather than reporting an empty change set."
            exit 1
          fi
          if [[ "$BEFORE" != "0000000000000000000000000000000000000000" ]] \\
             && ! git cat-file -e "${BEFORE}^{commit}" 2>/dev/null; then
            echo "::error::Base commit $BEFORE is not present in this checkout (force-push,"
            echo "::error::shallow clone, or rewritten history). The changed-file list is"
            echo "::error::unreliable and an empty one would be meaningless. Refusing."
            exit 1
          fi
          N=$(printf '%s\\n' "${{ steps.files.outputs.changed_files }}" | grep -c . || true)
          echo "count=$N" >> $GITHUB_OUTPUT
          if [[ "$N" == "0" ]]; then
            echo "::notice::No .sql or .rw files changed under pipelines/. Nothing will be"
            echo "::notice::applied and the execute job will be SKIPPED, not run empty."
          else
            echo "change detection OK: $N pipeline file(s) to apply"
          fi

'''

# ---- C: skip execute when there is nothing to apply ---------------------------------
EXEC_OLD = """  execute:
    needs: [validate, approve]
    runs-on: risingwave-pipeline
"""
EXEC_NEW = """  execute:
    needs: [validate, approve]

    # A run with nothing to apply must not look like a run that deployed. Before this, an
    # empty file list still produced a fully green execute job -- credentials pulled, psql
    # installed, both apply steps silently skipped, run reported success. Skipping the job
    # outright is visibly different in the UI and in the API.
    if: needs.validate.outputs.changed_count != '0'

    runs-on: risingwave-pipeline
"""

for name, old, new in (("validate outputs", OUT_OLD, OUT_NEW),
                       ("execute job header", EXEC_OLD, EXEC_NEW)):
    n = text.count(old)
    if n != 1:
        sys.exit(f"ERROR: expected exactly 1 match for the {name}, found {n}.\n"
                 f"       Read {wf} before patching.")
    text = text.replace(old, new)

n = text.count(GUARD_ANCHOR)
if n != 1:
    sys.exit(f"ERROR: expected exactly 1 fixture-guard block to anchor on, found {n}.\n"
             f"       Apply patch-rw-pipeline-prod-fixture-guard.py first.")
text = text.replace(GUARD_ANCHOR, DETECT_STEP + GUARD_ANCHOR)

wf.write_text(text)
print(f"patched {wf}\n")
subprocess.run(["git", "-C", str(repo), "--no-pager", "diff"], check=False)
print("\nVerify by RUNNING it: a README-only change under pipelines/ must now show execute")
print("as SKIPPED, not green. A real .rw change must still run it.")

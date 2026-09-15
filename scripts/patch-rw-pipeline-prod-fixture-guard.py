#!/usr/bin/env python3
"""Refuse test fixtures on production, and stop defaulting an unknown ref to dev.

Found 2026-09-15. `master` maps to ENV=prod, and `pipelines/canary/001-promotion-canary.rw`
is on master and not on dev. It ran there 22 hours ago (run 34600348974) and failed ONLY
because the role was broken -- which we fixed today. The next merge to master touching
`pipelines/**` would execute it against production RisingWave with a working credential
path.

Two things stand in the way and neither is a control: there is no `prod` GitHub environment
yet, so the coordinates resolve empty; and prod's Secrets Manager paths may not exist. Both
are accidents of incompleteness that someone will "fix" without knowing they are load
bearing.

⚠️ REFUSE, DO NOT DELETE. That canary belongs to the ARGO CD delivery path -- its own
header says so ("author -> build -> promotion PR -> Argo CD -> apply.sh -> RisingWave").
Two systems read `pipelines/`; this workflow picking up a file written for the other one is
the accident. Deleting it would break somebody else's work to fix ours.

Second change: `else ENV="dev"` silently sent any unrecognised ref to dev. Harmless while
the trigger lists exactly three branches, and a silent mis-deploy the moment someone adds a
fourth. It now fails.

    python3 scripts/patch-rw-pipeline-prod-fixture-guard.py /tmp/risingwave-pipeline
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

FALLBACK_OLD = """          else
            ENV="dev"
          fi
"""
FALLBACK_NEW = """          else
            # Previously defaulted to dev. An unrecognised ref is a question, not a dev
            # deploy -- and the answer stops being harmless the moment someone adds a
            # fourth branch to the trigger above.
            echo "::error::Unrecognised ref '${{ github.ref }}'. Add it to env-detect and to"
            echo "::error::the push trigger deliberately; this job will not guess."
            exit 1
          fi
"""

GUARD_ANCHOR = "      - name: SQL guardrails"
GUARD_STEP = """      # Fixtures create objects. On dev and qa that is their purpose; on prod it is an
      # unrequested production mutation. Fails CLOSED: an unreadable environment or file
      # list lands in the prod branch of the check and stops the run.
      #
      # REFUSES rather than deletes, because pipelines/canary/ belongs to the Argo CD
      # delivery path and legitimately lives on master for it. Two systems read pipelines/;
      # this workflow treating another system's fixture as deployable is the defect.
      - name: Refuse test fixtures on production
        shell: bash
        run: |
          ENVN="${{ steps.env-detect.outputs.environment }}"
          if [[ -z "$ENVN" ]]; then
            echo "::error::env-detect produced no environment. Refusing rather than assuming."
            exit 1
          fi
          if [[ "$ENVN" != "prod" ]]; then
            echo "environment is $ENVN -- test fixtures are allowed here."
            exit 0
          fi

          FIXTURES=$(printf '%s\\n' "${{ steps.files.outputs.changed_files }}" \\
                     | grep -E '^pipelines/(canary|_connectivity)/' || true)
          if [[ -n "$FIXTURES" ]]; then
            echo "::error::Test fixtures must never execute against PRODUCTION."
            printf '%s\\n' "$FIXTURES" | sed 's/^/::error::  /'
            echo "::error::These directories exist to prove a delivery path on dev and qa."
            echo "::error::If a prod run genuinely needs one, move it out of these directories"
            echo "::error::and say so in the PR -- do not weaken this check."
            exit 1
          fi
          echo "No test fixtures in this change; safe to continue to prod."

"""

for name, old, new in (("env fallback", FALLBACK_OLD, FALLBACK_NEW),):
    n = text.count(old)
    if n != 1:
        sys.exit(f"ERROR: expected exactly 1 match for the {name}, found {n}.\n"
                 f"       Read {wf} before patching.")
    text = text.replace(old, new)

n = text.count(GUARD_ANCHOR)
if n != 1:
    sys.exit(f"ERROR: expected exactly 1 '{GUARD_ANCHOR}' step, found {n}.\n"
             f"       Read {wf} before patching.")
text = text.replace(GUARD_ANCHOR, GUARD_STEP + GUARD_ANCHOR)

wf.write_text(text)
print(f"patched {wf}\n")
subprocess.run(["git", "-C", str(repo), "--no-pager", "diff"], check=False)
print("\nVerify by RUNNING it, not by merging it: after this lands on master, a PR to master")
print("touching pipelines/_connectivity/ must FAIL at validate. A merge to dev must still pass.")

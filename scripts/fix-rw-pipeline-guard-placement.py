#!/usr/bin/env python3
"""Move the fixture-guard step above the SQL Guardrails comment banner.

The first version anchored on `- name: SQL guardrails` and inserted before it, which left
that step's own banner comment -- "Blocks the pipeline if any changed file contains: DROP
TABLE / TRUNCATE ..." -- stranded above the NEW step, where it reads as a description of
the fixture check. A comment that describes the wrong step is worse than no comment.

Behaviour is identical either way; this is purely about the file being readable by whoever
comes next.

    python3 scripts/fix-rw-pipeline-guard-placement.py /tmp/risingwave-pipeline
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
START = "      # Fixtures create objects."
END = '          echo "No test fixtures in this change; safe to continue to prod."\n\n'
BANNER = "      # ── SQL Guardrails"

if text.count(START) != 1 or text.count(END) != 1:
    sys.exit("ERROR: the fixture-guard block is not present exactly once. Apply\n"
             "       patch-rw-pipeline-prod-fixture-guard.py first.")
if text.count(BANNER) != 1:
    sys.exit(f"ERROR: expected exactly 1 '{BANNER}' banner, found {text.count(BANNER)}.")

s = text.index(START)
e = text.index(END) + len(END)
block = text[s:e]
rest = text[:s] + text[e:]

if rest.index(BANNER) < s:
    sys.exit("ERROR: the banner is already above the guard -- nothing to move.")

text = rest.replace(BANNER, block + BANNER)
wf.write_text(text)
print(f"moved the fixture guard above the SQL Guardrails banner in {wf}\n")
subprocess.run(["git", "-C", str(repo), "--no-pager", "diff"], check=False)

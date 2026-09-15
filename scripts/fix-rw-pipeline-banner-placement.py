#!/usr/bin/env python3
"""Move the SQL Guardrails banner comment back down to the step it describes.

Two steps have since been inserted between that banner and `- name: SQL guardrails`:
`Verify change detection ran` and `Refuse test fixtures on production`. So a comment listing
DROP TABLE, TRUNCATE and injection fingerprints now sits above a change-detection check and
a fixture guard, describing neither of them.

Behaviour is untouched; this is purely so the file reads correctly. A comment attached to the
wrong step is worse than no comment -- the next person trusts it.

    python3 scripts/fix-rw-pipeline-banner-placement.py /tmp/risingwave-pipeline
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

BANNER = "      # ── SQL Guardrails"
NEXT_COMMENT = "      # The step above ends every branch"
STEP = "      - name: SQL guardrails"

for label, needle in (("guardrails banner", BANNER),
                      ("detect-check comment", NEXT_COMMENT),
                      ("guardrails step", STEP)):
    if text.count(needle) != 1:
        sys.exit(f"ERROR: expected exactly 1 {label}, found {text.count(needle)}.\n"
                 f"       Apply the empty-change-set patch first, and read {wf}.")

start = text.index(BANNER)
end = text.index(NEXT_COMMENT)
if end < start:
    sys.exit("ERROR: the banner is already below the inserted steps -- nothing to move.")

block = text[start:end]
rest = text[:start] + text[end:]
text = rest.replace(STEP, block + STEP)

wf.write_text(text)
print(f"moved the SQL Guardrails banner onto its own step in {wf}\n")
subprocess.run(["git", "-C", str(repo), "--no-pager", "diff"], check=False)

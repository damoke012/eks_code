#!/usr/bin/env python3
"""Four-case test of the prod fixture guard, against the text actually in the workflow.

The workflow triggers on `push` only, so a pull request runs nothing and its checks cannot
tell you whether the guard works. The only integration test is merging a fixture to master
-- which is the event the guard exists to prevent. So extract the shipped step and run it.

This reads the `Refuse test fixtures on production` step out of pipeline.yaml, substitutes
the two GitHub expressions, and runs it under four inputs. Per authoring-gate-hooks, the
middle two are the ones nobody writes:

  1. dev + fixtures present            -> allow (0)   fixtures are the point on dev
  2. prod + fixtures present           -> BLOCK (1)   the case that matters
  3. prod + no fixtures                -> allow (0)   must not block real promotions
  4. environment EMPTY + fixtures      -> BLOCK (1)   fail closed on an unreadable input

Case 4 is the fail-open trap: a guard that reads an empty environment as "not prod" waves
through exactly the runs whose environment it could not determine.

    python3 scripts/test-rw-pipeline-fixture-guard.py /tmp/risingwave-pipeline
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

if len(sys.argv) != 2:
    sys.exit(__doc__)
wf = Path(sys.argv[1]) / ".github/workflows/pipeline.yaml"
if not wf.exists():
    sys.exit(f"ERROR: no {wf}")

text = wf.read_text()
m = re.search(r"- name: Refuse test fixtures on production\n"
              r"\s+shell: bash\n\s+run: \|\n(.*?)(?=\n      - name: )", text, re.S)
if not m:
    sys.exit("ERROR: could not find the 'Refuse test fixtures on production' step.\n"
             "       It is not in this branch's workflow, so there is nothing to test.")

body = "\n".join(ln[10:] if ln.startswith(" " * 10) else ln
                 for ln in m.group(1).split("\n"))
body = (body.replace("${{ steps.env-detect.outputs.environment }}", "$TEST_ENV")
            .replace("${{ steps.files.outputs.changed_files }}", "$TEST_FILES"))

CASES = [
    ("dev + fixtures",        "dev",  "pipelines/_connectivity/100-postgres-connectivity.sql", 0),
    ("prod + fixtures",       "prod", "pipelines/_connectivity/100-postgres-connectivity.sql", 1),
    ("prod + canary fixture", "prod", "pipelines/canary/001-promotion-canary.rw",              1),
    ("prod + real pipeline",  "prod", "pipelines/Brand/100-sources.rw",                        0),
    ("EMPTY env + fixtures",  "",     "pipelines/_connectivity/100-postgres-connectivity.sql", 1),
]

with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
    f.write(body)
    script = f.name

fails = 0
for name, env, files, want in CASES:
    r = subprocess.run(["bash", script], capture_output=True, text=True,
                       env={"TEST_ENV": env, "TEST_FILES": files, "PATH": "/usr/bin:/bin"})
    got = 1 if r.returncode != 0 else 0
    ok = "PASS" if got == want else "FAIL"
    fails += ok == "FAIL"
    verdict = "BLOCK" if got else "allow"
    print(f"  [{ok}] {name:24} -> {verdict:5} (wanted {'BLOCK' if want else 'allow'})")
    if ok == "FAIL":
        print("        " + (r.stdout + r.stderr).strip().replace("\n", "\n        ")[:400])

Path(script).unlink()
print()
if fails:
    sys.exit(f"{fails} case(s) FAILED -- the guard does not do what the PR claims.")
print("All cases pass. Note this tests the STEP, not its wiring: it does not prove the step")
print("is reached, only that it decides correctly once it runs.")

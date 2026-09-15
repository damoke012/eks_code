#!/usr/bin/env python3
"""Point the dev arm of risingwave-pipeline at `risingwave`, not `risingwave-2`.

Decided 2026-09-15. Idris, asked directly "should the pipeline be RW or RW-2?":
"rw. rw-2 is ours."

The pipeline under test is TIM's SQL pipeline, and `risingwave` on op-usxpress-dev is
the APPLICATION's dev environment -- the four Brand objects (brand_source_kafka,
brand_mv_raw/state/flat) are there and nowhere else. `risingwave-2` was stood up on
2026-05-27 as the PLATFORM team's own sandbox, explicitly so our CI/CD work could not
disturb Tim's; it holds zero sources, MVs and sinks, verified over rw_catalog on
2026-09-15. Repointing the application's pipeline into our sandbox was the error --
it read as "a namespace per team" when the real axis is "a namespace per purpose".

With dev on `risingwave` the namespace and the role stop varying by environment
entirely, so this removes them from the case statement rather than correcting one arm.
A constant that nobody can set per-environment cannot drift per-environment; the
2026-09-14 defect was exactly that drift (the role fitted dev alone, by coincidence).

⚠️ THIS IS HALF THE CHANGE. RW_NS selects the Secrets Manager path and the OIDC role.
It does NOT decide where psql connects -- that is RISINGWAVE_HOST / RISINGWAVE_PORT on
the GitHub `dev` environment, documented in wip/rw2-sql-cicd/ as
`risingwave-frontend.risingwave-2.svc.cluster.local`. Change that too or the job will
read Tim's credentials and apply them to our empty instance.

    python3 scripts/patch-rw-pipeline-dev-namespace.py /tmp/risingwave-pipeline
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

OLD = """          # ROLE_KIND must track RW_NS. The poc role grants .../risingwave/*, the
          # pipeline role grants .../risingwave-2/* -- so the secret path this job
          # reads decides which role can read it. Set both here, never separately.
          case "$ENV" in
            dev)  AWS_ACCOUNT_ID="700736442855"; RW_NS="risingwave-2"; ROLE_KIND="pipeline" ;;
            qa)   AWS_ACCOUNT_ID="527101283767"; RW_NS="risingwave";   ROLE_KIND="poc" ;;
            prod) AWS_ACCOUNT_ID="937464026810"; RW_NS="risingwave";   ROLE_KIND="poc" ;;
            *)    echo "::error::Unknown environment '${ENV}'"; exit 1 ;;
          esac
"""

NEW = """          # The application's ETL lives in `risingwave` in EVERY environment, dev
          # included -- confirmed by Idris 2026-09-15 ("rw. rw-2 is ours"). On dev,
          # `risingwave-2` is the platform team's own sandbox, created so our CI/CD
          # work could not disturb Tim's; it holds none of the application's objects.
          # So neither the namespace nor the role varies by environment any more, and
          # they are deliberately NOT in the case statement: a constant nobody can set
          # per-environment cannot drift per-environment, which is the exact defect
          # fixed on 2026-09-14 (the role fitted dev alone, by coincidence).
          # The poc role is the one that grants .../risingwave/*.
          RW_NS="risingwave"
          ROLE_KIND="poc"
          case "$ENV" in
            dev)  AWS_ACCOUNT_ID="700736442855" ;;
            qa)   AWS_ACCOUNT_ID="527101283767" ;;
            prod) AWS_ACCOUNT_ID="937464026810" ;;
            *)    echo "::error::Unknown environment '${ENV}'"; exit 1 ;;
          esac
"""

n = text.count(OLD)
if n != 1:
    sys.exit(f"ERROR: expected exactly 1 match for the env-detect case block, found {n}.\n"
             f"       {wf} has moved on since 2026-09-15 -- read it before patching.")

wf.write_text(text.replace(OLD, NEW))
print(f"patched {wf}\n")
subprocess.run(["git", "-C", str(repo), "--no-pager", "diff"], check=False)
print("\nReminder: RISINGWAVE_HOST / RISINGWAVE_PORT on the GitHub `dev` environment\n"
      "still point at risingwave-2. This patch does not touch them.")

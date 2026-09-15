#!/usr/bin/env python3
"""Patch risingwave-pipeline's pipeline.yaml so promotion to qa and dev actually runs.

Two defects, both proven from source plus the live IAM policies on 2026-09-14:

1. TRIGGER. `on: push: branches: [master]` on every branch -- master, qa and dev all
   carry the identical file, checked, so a merge into qa fires nothing. The env-detect
   block has qa and dev cases that are unreachable. Run history agrees: three runs
   ever, all on master, all failed.

2. ROLE. The step always assumes gha-op-usxpress-<env>-risingwave-PIPELINE-secrets, but
   asks for op-usxpress-<env>/<rw_ns>/postgres where rw_ns is risingwave-2 on dev and
   risingwave on qa/prod. The pipeline role grants only .../risingwave-2/*; the poc role
   grants .../risingwave/*. So it works on DEV ONLY, by coincidence -- dev is the one
   environment where the namespace string and the role's granted path are the same.
   Same shape as the secret.yaml defect fixed by risingwave-pipeline #32, but NOT the
   same fix: dev must keep the pipeline role. The role has to follow the namespace, so
   this sets both in one case arm and they cannot drift apart.

Refuses unless it finds the exact expected text, so a file that has moved on since
2026-09-15 fails loudly rather than getting mangled.

    python3 scripts/patch-rw-pipeline-promotion.py /tmp/risingwave-pipeline
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

TRIGGER_OLD = """on:
  push:
    branches:
      - master

    paths:
      - 'pipelines/**'
"""
TRIGGER_NEW = """on:
  push:
    branches:
      # One branch per environment. env-detect below maps ref -> account, namespace
      # and role; before 2026-09-15 only master was listed, so its qa and dev cases
      # were unreachable and a merge into qa ran nothing at all.
      - master
      - qa
      - dev

    paths:
      - 'pipelines/**'
"""

CASE_OLD = """          case "$ENV" in
            dev)  AWS_ACCOUNT_ID="700736442855"; RW_NS="risingwave-2" ;;
            qa)   AWS_ACCOUNT_ID="527101283767"; RW_NS="risingwave" ;;
            prod) AWS_ACCOUNT_ID="937464026810"; RW_NS="risingwave" ;;
            *)    echo "::error::Unknown environment '${ENV}'"; exit 1 ;;
          esac
"""
CASE_NEW = """          # ROLE_KIND must track RW_NS. The poc role grants .../risingwave/*, the
          # pipeline role grants .../risingwave-2/* -- so the secret path this job
          # reads decides which role can read it. Set both here, never separately.
          case "$ENV" in
            dev)  AWS_ACCOUNT_ID="700736442855"; RW_NS="risingwave-2"; ROLE_KIND="pipeline" ;;
            qa)   AWS_ACCOUNT_ID="527101283767"; RW_NS="risingwave";   ROLE_KIND="poc" ;;
            prod) AWS_ACCOUNT_ID="937464026810"; RW_NS="risingwave";   ROLE_KIND="poc" ;;
            *)    echo "::error::Unknown environment '${ENV}'"; exit 1 ;;
          esac
"""

ROLE_OLD = ('echo "aws_role=arn:aws:iam::${AWS_ACCOUNT_ID}:role/'
            'gha-op-usxpress-${ENV}-risingwave-pipeline-secrets" >> $GITHUB_OUTPUT')
ROLE_NEW = ('echo "aws_role=arn:aws:iam::${AWS_ACCOUNT_ID}:role/'
            'gha-op-usxpress-${ENV}-risingwave-${ROLE_KIND}-secrets" >> $GITHUB_OUTPUT')

for name, old, new in (("trigger", TRIGGER_OLD, TRIGGER_NEW),
                       ("env case", CASE_OLD, CASE_NEW),
                       ("role arn", ROLE_OLD, ROLE_NEW)):
    n = text.count(old)
    if n != 1:
        sys.exit(f"ERROR: expected exactly 1 match for the {name} block, found {n}.\n"
                 f"       pipeline.yaml has changed -- re-read it before patching.")
    text = text.replace(old, new)

wf.write_text(text)
print(f"patched {wf}\n")
subprocess.run(["git", "-C", str(repo), "--no-pager", "diff", "--stat"], check=False)
print()
subprocess.run(["git", "-C", str(repo), "--no-pager", "diff"], check=False)

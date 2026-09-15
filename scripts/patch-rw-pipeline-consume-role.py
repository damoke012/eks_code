#!/usr/bin/env python3
"""Make the execute job USE the role env-detect computed, instead of a hardcoded ARN.

Found 2026-09-15 on all three branches of variant-inc/risingwave-pipeline, identically:

  line  35  aws_role: ${{ steps.env-detect.outputs.aws_role }}      <- exposed as an output
  line  79  echo "aws_role=arn:aws:iam::${AWS_ACCOUNT_ID}:role/..." <- computed per env
  line 226  role-to-assume: arn:aws:iam::700736442855:role/gha-op-usxpress-dev-risingwave-pipeline-secrets

The value was produced and published and then read by nothing. Two consequences:

1. Every environment assumed the DEV account's role. A QA run reached for a role in
   700736442855 while its secret path interpolated to op-usxpress-qa/... -- wrong account,
   not merely wrong role. QA promotion could never have worked even once the trigger was
   fixed, and the three historical runs' exit 254 is consistent with this.
2. risingwave-pipeline #33 (role follows namespace) and #35 (dev moves to `risingwave`)
   both edited the producer. Neither changed behaviour, because nothing consumed it. Both
   reviewed clean.

The general shape: a computed value that is never read looks correct in review at BOTH
ends -- the producer is right, the consumer is a literal that is also syntactically fine.
Only following the wire catches it. Related: eks_code memory adjacent-step-green-signals.

    python3 scripts/patch-rw-pipeline-consume-role.py /tmp/risingwave-pipeline
"""
import re
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

OLD = ("          role-to-assume: arn:aws:iam::700736442855:role/"
       "gha-op-usxpress-dev-risingwave-pipeline-secrets\n")
NEW = ("          # Consume what env-detect computed. This was hardcoded to the DEV account's\n"
       "          # pipeline role on every branch, so a qa or prod run reached for a role in\n"
       "          # 700736442855 while its secret path interpolated to op-usxpress-qa/... --\n"
       "          # the wrong ACCOUNT, not merely the wrong role. The aws_role output existed,\n"
       "          # was exposed as a job output, and was read by nothing.\n"
       "          role-to-assume: ${{ needs.validate.outputs.aws_role }}\n")

n = text.count(OLD)
if n != 1:
    sys.exit(f"ERROR: expected exactly 1 hardcoded role-to-assume, found {n}.\n"
             f"       Read {wf} before patching.")
text = text.replace(OLD, NEW)
wf.write_text(text)
print(f"patched {wf}\n")

# Any other account id baked into the file is the same defect wearing a different hat.
leftovers = [(i, ln.strip()) for i, ln in enumerate(text.splitlines(), 1)
             if re.search(r"\b(700736442855|527101283767|937464026810)\b", ln)
             and "AWS_ACCOUNT_ID=" not in ln]
if leftovers:
    print("REMAINING hardcoded account ids outside the env-detect case statement:")
    for i, ln in leftovers:
        print(f"  {i}: {ln[:120]}")
    print()
else:
    print("No account id is hardcoded outside the env-detect case statement.\n")

subprocess.run(["git", "-C", str(repo), "--no-pager", "diff"], check=False)

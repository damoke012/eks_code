#!/usr/bin/env python3
"""Declare the GitHub environment on the execute job, so OIDC and env secrets both work.

Proven 2026-09-15 by reading both accounts' trust policies against a failing run.

The poc role in BOTH dev and qa trusts only:

    token.actions.githubusercontent.com:sub =
      repo:variant-inc/risingwave-pipeline:environment:dev | :environment:qa | :environment:prod

A job's OIDC subject carries `environment:<name>` ONLY if the job declares
`environment:`. The execute job declares none, so its subject is
`repo:variant-inc/risingwave-pipeline:ref:refs/heads/<branch>` and matches nothing on
either poc role. Result: "Not authorized to perform sts:AssumeRoleWithWebIdentity".

This also explains the run history rather than merely fixing today. dev's PIPELINE role
trusts `ref:refs/heads/master` and nothing else -- which is exactly why the old hardcoded
role got PAST OIDC on master pushes and then died at the secret path, and why a push to
any other branch could never have authenticated at all.

Second effect, same cause: environment-scoped secrets are invisible to a job that
declares no environment. RISINGWAVE_HOST and POSTGRES_HOST live on the `dev`
environment, so they were resolving to empty regardless of their value.

    python3 scripts/patch-rw-pipeline-declare-environment.py /tmp/risingwave-pipeline
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

OLD = """  execute:
    needs: [validate, approve]
    runs-on: risingwave-pipeline
"""
NEW = """  execute:
    needs: [validate, approve]
    runs-on: risingwave-pipeline

    # REQUIRED, and for two reasons that share one cause.
    #
    # 1. OIDC. The poc role in every account trusts
    #      ...:sub = repo:variant-inc/risingwave-pipeline:environment:{dev|qa|prod}
    #    A job's subject carries `environment:<name>` only if the job DECLARES an
    #    environment. Without this line the subject is `...:ref:refs/heads/<branch>`,
    #    which matches no condition on the poc role, and the run dies at "Configure AWS
    #    via OIDC" with "Not authorized to perform sts:AssumeRoleWithWebIdentity".
    # 2. Secrets. RISINGWAVE_HOST, RISINGWAVE_PORT, POSTGRES_HOST and POSTGRES_PORT are
    #    environment-scoped. A job with no environment cannot read them and gets empty
    #    strings, with no error.
    #
    # Must stay in step with validate's `environment` output, which is derived from the
    # branch. Do not hardcode it -- that is the defect fixed one commit earlier.
    environment: ${{ needs.validate.outputs.environment }}
"""

n = text.count(OLD)
if n != 1:
    sys.exit(f"ERROR: expected exactly 1 execute job header, found {n}.\n"
             f"       Read {wf} before patching.")
wf.write_text(text.replace(OLD, NEW))
print(f"patched {wf}\n")
subprocess.run(["git", "-C", str(repo), "--no-pager", "diff"], check=False)
print("\nAfter this merges, the OIDC subject becomes")
print("  repo:variant-inc/risingwave-pipeline:environment:dev")
print("which both dev and qa poc roles already trust. No IAM change is needed.")

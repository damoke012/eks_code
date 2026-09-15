#!/usr/bin/env python3
"""Write a connectivity-only pipeline file into a risingwave-pipeline clone.

Run 34976661219 proved OIDC, the role and both Secrets Manager reads on dev -- but its
"Execute SQL files" steps were SKIPPED, because the changed-file list was empty by design.
So the network hop to Postgres and to RisingWave, and the values of the environment-scoped
connection secrets, are still unproven. A run that skips the step that matters is not a
test of that step.

These two files close that gap without touching anything Tim owns:

  * no DDL, no writes, no transactions
  * no reference to any existing source, table, view or sink
  * live in their own pipelines/_connectivity/ directory, so no other pipeline's file list
    is affected
  * idempotent -- re-running changes nothing

They deliberately do NOT prove that DDL works. That needs a real object, and creating one
in Tim's instance is a conversation, not a side effect of a connectivity check.

Merge them ONE AT A TIME. The executor runs .sql against Postgres and .rw against
RisingWave, driven by which files changed -- so a single commit touching both proves two
things at once and tells you nothing about which one failed.

    python3 scripts/rw-pipeline-connectivity-test.py /tmp/risingwave-pipeline sql
    python3 scripts/rw-pipeline-connectivity-test.py /tmp/risingwave-pipeline rw
"""
import subprocess
import sys
from pathlib import Path

if len(sys.argv) != 3 or sys.argv[2] not in ("sql", "rw"):
    sys.exit(__doc__)
repo, which = Path(sys.argv[1]), sys.argv[2]
if not (repo / ".github/workflows/pipeline.yaml").exists():
    sys.exit(f"ERROR: {repo} is not a risingwave-pipeline clone.")

d = repo / "pipelines/_connectivity"
d.mkdir(parents=True, exist_ok=True)

# Guardrail-safe by construction: no DROP, no TRUNCATE, no DELETE, no UNION SELECT, no
# quoted tautology, no statement stacking. Checked against the patterns in validate.
SQL = """-- Connectivity check for the POSTGRES leg of the pipeline. Read-only.
--
-- Added 2026-09-15. Run 34976661219 went green while SKIPPING both execute steps, because
-- the changed-file list was empty -- so nothing had ever dialled POSTGRES_HOST from the
-- runner. This is the smallest file that does.
--
-- It creates nothing, alters nothing, and names no object belonging to another pipeline.
-- If it fails, the fault is the network path, the credential, or POSTGRES_HOST/PORT on the
-- GitHub environment -- never this file.

SELECT current_database() AS database,
       current_user       AS connected_as,
       version()          AS server_version,
       now()              AS checked_at;
"""

RW = """-- Connectivity check for the RISINGWAVE leg of the pipeline. Read-only.
--
-- Added 2026-09-15, same reason as the .sql alongside it: the first green run skipped both
-- execute steps, so RISINGWAVE_HOST had never been dialled from the runner.
--
-- Creates nothing and names no source, table, view or sink. Tim's objects in the
-- `risingwave` namespace on op-usxpress-dev are untouched by this file.
--
-- If it fails, the fault is the network path to risingwave-frontend:4567, the root
-- credential, or RISINGWAVE_HOST/PORT on the GitHub environment.

SELECT version() AS server_version;

SHOW DATABASES;
"""

name = "100-postgres-connectivity.sql" if which == "sql" else "200-risingwave-connectivity.rw"
(d / name).write_text(SQL if which == "sql" else RW)

readme = d / "README.md"
if not readme.exists():
    readme.write_text(
        "# _connectivity\n\n"
        "Connectivity checks, not part of any data pipeline. Read-only `SELECT`s that prove the\n"
        "runner can reach Postgres and RisingWave with the credentials the workflow pulls.\n\n"
        "They exist because a run whose execute steps are SKIPPED still reports success. Keep\n"
        "them free of DDL: the moment one of these creates an object, a failure here stops\n"
        "meaning \"the connection is broken\" and starts meaning several things at once.\n")

print(f"wrote {d / name}\n")
subprocess.run(["git", "-C", str(repo), "status", "--short"], check=False)
print(f"\nCommit and merge THIS FILE ONLY, then watch the "
      f"{'Execute SQL files on PostgreSQL' if which == 'sql' else 'Execute RW files on RisingWave'} step.")

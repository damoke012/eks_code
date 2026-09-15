#!/usr/bin/env python3
"""Write a DDL canary: proves the pipeline can CREATE, not merely connect.

The connectivity checks are read-only SELECTs. They prove the runner reaches Postgres and
RisingWave with working credentials -- and nothing else. Every real pipeline file is DDL:
CREATE SOURCE, CREATE MATERIALIZED VIEW, CREATE SINK. So the capability promotion actually
depends on is completely untested, and a green connectivity run is not evidence about it.

These canaries close that gap WITHOUT touching anything Tim owns, by putting every object
in a schema of their own:

  * `pipeline_canary` schema, created if absent -- Tim's objects are in `public`
  * names are unmistakably ours: pipeline_canary.ddl_probe, .ddl_probe_mv
  * every DROP is `IF EXISTS`, so re-running is idempotent AND passes the guardrails
    (the validate step exempts IF EXISTS and blocks unguarded DROPs)
  * the Postgres one lands in database `postgres`, which the earlier survey found EMPTY

What they exercise: CREATE SCHEMA, CREATE TABLE, INSERT, and on RisingWave CREATE
MATERIALIZED VIEW -- the DDL shapes the real pipelines use, minus CREATE SOURCE, which
needs live Kafka credentials and is worth proving separately once these pass.

    python3 scripts/rw-pipeline-ddl-canary.py /tmp/risingwave-pipeline sql
    python3 scripts/rw-pipeline-ddl-canary.py /tmp/risingwave-pipeline rw
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

# Statement stacking (`; DROP`) is matched per LINE by the guardrail, so every DROP starts
# its own line. Keep it that way if you edit these.
SQL = """-- DDL canary for the POSTGRES leg. Proves CREATE works, not merely that we can connect.
--
-- Everything lives in the `pipeline_canary` schema. Nothing outside it is read or written,
-- and no object belonging to another pipeline is named anywhere in this file.
-- Re-running is idempotent: the DROPs are all IF EXISTS.

CREATE SCHEMA IF NOT EXISTS pipeline_canary;

DROP TABLE IF EXISTS pipeline_canary.ddl_probe;

CREATE TABLE pipeline_canary.ddl_probe (
  id         INT PRIMARY KEY,
  checked_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO pipeline_canary.ddl_probe (id) VALUES (1);

SELECT count(*) AS rows_in_probe FROM pipeline_canary.ddl_probe;
"""

RW = """-- DDL canary for the RISINGWAVE leg. Proves CREATE TABLE and CREATE MATERIALIZED VIEW
-- work, which is what every real pipeline file does and what the SELECT-only checks do not
-- cover.
--
-- Everything lives in the `pipeline_canary` schema. Tim's objects are in `public`:
-- brand_source_kafka, brand_mv_raw, brand_mv_state and brand_mv_flat are neither named nor
-- read here. Re-running is idempotent: every DROP is IF EXISTS.
--
-- CREATE SOURCE is deliberately absent -- it needs live Kafka credentials and a topic, and
-- belongs in its own check once this one passes.

CREATE SCHEMA IF NOT EXISTS pipeline_canary;

DROP MATERIALIZED VIEW IF EXISTS pipeline_canary.ddl_probe_mv;

DROP TABLE IF EXISTS pipeline_canary.ddl_probe;

CREATE TABLE pipeline_canary.ddl_probe (
  id         INT PRIMARY KEY,
  checked_at TIMESTAMPTZ
);

INSERT INTO pipeline_canary.ddl_probe (id, checked_at) VALUES (1, now());

CREATE MATERIALIZED VIEW pipeline_canary.ddl_probe_mv AS
  SELECT count(*) AS row_count FROM pipeline_canary.ddl_probe;
"""

name = "300-ddl-canary.sql" if which == "sql" else "400-ddl-canary.rw"
(d / name).write_text(SQL if which == "sql" else RW)
print(f"wrote {d / name}\n")
subprocess.run(["git", "-C", str(repo), "status", "--short"], check=False)
print("\nAfter the run, confirm the objects EXIST -- a green step is not an object:")
if which == "rw":
    print("  RW_NS=risingwave bash scripts/rw-sql.sh dev \\\n"
          "    \"SELECT name FROM rw_catalog.rw_materialized_views WHERE name LIKE 'ddl_probe%';\"")
else:
    print("  psql ... -c \"\\dt pipeline_canary.*\"   (or re-run the canary; it reports its row count)")

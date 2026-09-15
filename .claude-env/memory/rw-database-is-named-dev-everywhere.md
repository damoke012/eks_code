---
name: rw-database-is-named-dev-everywhere
description: "RisingWave's internal database is named `dev` on every on-prem cluster incl. QA; RW_DB must never be set to the environment name"
metadata:
  type: project
---

On **op-usxpress-qa**, `SHOW DATABASES` returns exactly one row: **`dev`** (verified by SQL
2026-09-11 via `scripts/rw-verify-canary.sh qa`). `dev` is RisingWave's default database name,
not an environment label — it is the same on every cluster.

**Why:** in `risingwave-pipeline` PR #29 the env var `RW_DB` was changed from `dev` to `qa`
"to match the environment". There is no database called `qa`, so every connection would have
failed at connect time with a green deploy behind it. The name looks like a mistake in QA and
is not one.

**How to apply:** never parameterise `RW_DB` by environment. If a change sets it to `qa` or
`prod`, that is the defect. Confirm with `bash scripts/rw-sql.sh <env> "SHOW DATABASES;"`
before arguing about it — this was an inference from a log line for two days before anyone ran
the query. Related: [[risingwave-onprem]], [[proxy-is-not-the-property]].

---
name: qa-postgres-password-drift
description: "op-usxpress-qa pg-postgresql never learned its rotated password — initdb 2026-08-11, secret rotated 2026-08-12; fixed 2026-08-20, meta pod still to recreate"
metadata:
  type: project
---

**op-usxpress-qa, `risingwave` namespace.** `pg-postgresql` was initialised
**2026-08-11 19:20 UTC**. `op-usxpress-qa/risingwave/postgres` was rotated
**2026-08-12 13:35 UTC**. `POSTGRES_PASSWORD` applies **only at `initdb`**, so the database
kept the 08-11 value while Secrets Manager, `pg-credentials`, `risingwave-pg-credentials`
and the ETL Job all carried the 08-12 one — identical hashes, all four wrong.

Invisible for 8 days because of [[pod-env-secret-resolution]]: RisingWave meta's pod predates
the rotation. The first thing to use the credential fresh was INFRA-1648's smoke test.

**Fixed 2026-08-20** — `ALTER USER risingwave WITH PASSWORD` executed inside
`pg-postgresql-0`. `initdb` enabled `trust` for LOCAL connections, so no prior password is
needed for this; that is also worth knowing as a recovery route.

⚠️ **Outstanding:** the fix inverted meta's exposure. `risingwave-meta-default-0` still holds
the pre-rotation password in env, so a **container** restart now fails where a **pod**
recreation succeeds. Recreating that pod closes it. Belongs to Idris / INFRA-1624 — send the
timeline, do not fix it silently.

⚠️ **Check dev and prod for the same shape**: any Postgres built before its secret was
rotated has this fault, dormant until something recreates the pod.
`bash scripts/check-postgres-secret-usable.sh` answers it in one run — it compares initdb
against `LastChangedDate` and then actually authenticates over TCP.

Separately: 238 SIGSEGV restarts of RisingWave meta in its first 16 hours, unremarked.
Worth raising with Idris as its own question.

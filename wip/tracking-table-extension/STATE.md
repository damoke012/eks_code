# Tracking Table + Apply-All Extension — STATE
*Last updated 2026-05-27*

## Where it stands
Designing a lightweight RW-compatible alternative to Flyway, to be added to `pipeline.yaml` on `feat/onprem-rw2-adaptation` before the master PR. Flyway was rejected empirically — see [`../rw2-sql-cicd/STATE.md`](../rw2-sql-cicd/STATE.md).

## Goal
1. Per RW-2 namespace, keep a `pipeline_applied_files` table recording which `.sql` / `.rw` files have been executed (filename + commit SHA + applied_at).
2. Pipeline executes only files that aren't in the table yet — idempotency without relying on commit-diff alone (handles re-runs after pipeline-level failures).
3. **Apply-all bootstrap mode** — a `pipeline.yaml` input / branch convention that re-applies every `pipelines/**` file and (re)builds the tracking table from scratch. For first onboarding of a fresh RW cluster.

## Why not Flyway
- Flyway's `flyway_schema_history` requires types + a read-write transaction RW doesn't accept.
- RW is autocommit-only; locking semantics differ.

## Open design questions
- **Where does the table live?**
  - In RW itself (`dev.public.pipeline_applied_files`) — but RW resets on bootstrap, so we'd lose history.
  - **In backing postgres** (`postgres-postgresql.risingwave-2.svc:5432`) — more durable across RW restarts; **preferred**.
- **Schema sketch:**
  ```sql
  CREATE TABLE IF NOT EXISTS pipeline_applied_files (
    filename     TEXT PRIMARY KEY,
    commit_sha   TEXT NOT NULL,
    applied_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    file_kind    TEXT NOT NULL CHECK (file_kind IN ('sql','rw'))
  );
  ```
- **How to surface "apply-all" mode** — `workflow_dispatch` input? Special commit-message marker? Dedicated branch? Tradeoff: input is cleanest but `workflow_dispatch` workflows need to exist on the default branch to be dispatchable.
- **Failure recovery:** partial application of a multi-file change. Mark applied per-file at success, not at job end. Re-run picks up only the unapplied ones.
- **Compat:** existing `pipeline.yaml` uses `github.event.before..github.sha` diff — keep that as the *primary* file list, but cross-check against the tracking table to skip already-applied ones.

## Open items
| Item | Owner |
|------|-------|
| Decide table location (postgres vs RW) — recommend postgres | Doke + Idris |
| Draft schema + apply-all flow | Doke |
| Idris review of schema before PR | Idris |
| Add to pipeline.yaml on a sub-branch off `feat/onprem-rw2-adaptation` | Doke |

## Risk / watch-outs
- Whatever schema we pick is a durable contract — changing it later means migrating the tracking table itself, which is awkward.
- Postgres location means a postgres outage breaks the pipeline. Acceptable (postgres outage is a wider RW-2 incident anyway).

## What

Adds `pipelines/canary/001-promotion-canary.rw` — a self-contained RisingWave file that
creates a table, inserts one row, and builds a materialized view over it.

## Why

We have never proven the full delivery path end to end with a real pipeline file. The
QA cutover last night got as far as selecting the right two Brand files and then stopped
on three missing Kafka config values, which only Tim can supply. That leaves the path
itself unproven while we wait.

This file depends on **nothing outside RisingWave** — no Kafka, no application
PostgreSQL, no secrets. If it applies, we know the whole chain works: commit → image
build → promotion PR → Argo CD sync → `apply.sh` → RisingWave. If it fails, the failure
is the path, not a dependency.

## How it will be exercised

1. Merge this. The build workflow produces a new image.
2. Merge the promotion PR that opens against it.
3. A follow-up one-line PR points QA's `PIPELINE_DIR` at `/pipeline/pipelines/canary`
   so the run is the canary alone — `Brand/100-sources.rw` is still selected under the
   current `PIPELINE_DIR` and aborts the whole run on its missing `%KAFKA_…%` values
   before any file is applied.
4. Once it applies cleanly, `PIPELINE_DIR` goes back to `/pipeline/pipelines` and this
   file is removed.

## Notes

- Temporary. It is not part of the Brand cutover and should not survive it.
- Re-runnable: the leading `DROP`s mean a repeated apply reaches the same end state.
- It creates two objects in QA's RisingWave (`canary_promotion`,
  `canary_promotion_mv`), both named so they are obviously ours and trivially dropped.
- Prod is unaffected: that overlay still has `PIPELINE_DIR: /pipeline/smoke`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

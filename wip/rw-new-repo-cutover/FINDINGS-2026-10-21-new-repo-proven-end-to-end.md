# usxpressinc/risingwave: proven end to end, 2026-10-21

Tim Preble created the repo that morning. By 19:50 EDT a pipeline written in it was
running in RisingWave on op-dev, through every link of the chain.

## The chain, with timings from the real run

| | |
|---|---|
| Tim pushes to `master` | 23:24 UTC |
| `build-sql-image.yml` calls `iaac-risingwave-cicd@v1`, pushes `sha256:db42b04b…` | 23:24:53 |
| `promote.yml` (cron `*/10`) commits `fb2e326` pinning that digest | 23:36:22 |
| Argo CD syncs `risingwave-etl` from `risingwave-pipeline/deploy/chart` | within 5 min |
| `etl-pipeline-apply` Job runs and completes | 13 seconds |
| `rw_catalog.rw_sinks` holds `brand_sink_mongo`, `employees_sink_mongo` | ✅ measured |

**End to end, push to running pipeline: about 20 minutes, with no human step.**

## What had to be fixed to get there

1. **The OIDC trust.** The new repo emits an **immutable** subject,
   `repo:usxpressinc@101195652/risingwave@1428674918:ref:refs/heads/master`. Adding the
   plain `repo:org/name` form could never match, and the error named IAM throughout.
   See [[github-immutable-oidc-subject]].
2. **The Mongo sink URL.** Both sinks built `mongodb.url` from
   `MONGODB_HOST/PORT/USERNAME/PASSWORD`, which cannot address an `mongodb+srv` Atlas
   endpoint — SRV has no port. The working `%MONGODB_CONNECTION_STRING%` line was commented
   out directly above. It had been Tim's local workaround.

## Proven

* The build path works from a brand new repo in another GitHub org, with no stored credential.
* The applier image carries the per-env config fix — it loaded `pipelines/config/dev.env`.
* **The validator aborts on empty values** rather than substituting blanks. That is what
  surfaced a fault that had been silently present for weeks.
* Promotion is correct: newest by `imagePushedAt`, and it verifies its own `sed` landed.

## Tested and killed

* "Two promote runs skipped the image." **No** — I compared a relative age against a
  different clock. The run was 3 minutes BEFORE the push. **Read run timestamps, not "N
  minutes ago".**
* "The failed Job is blocking its replacement." No — Argo had nothing new to apply because
  the chart had not been promoted yet. The Job was replaced automatically once it was.
* "psql in the frontend pod." Not present. `postgres-postgresql-0` in the same namespace has
  it, and the frontend listens on **4567**, not RisingWave's default 4566.

## Traps

1. **A succeeded sync-hook Job deletes itself, log and all.** We caught `Completed` at 13s
   only because we happened to look. Read the log while the pod exists or not at all.
2. **A promote run is green whether or not it promoted anything.** Worth a check that fails
   when ECR holds a digest newer than the one dev runs.
3. **The deploy half is dev-only.** QA and prod promotion exists in `promote.yml` but moves
   only when a person runs it with `only=qa` / `only=prod`. Nothing automatic reaches them.

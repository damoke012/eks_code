# op-dev is running a branch, not master — 2026-08-28

## Proven

**Live on `op-usxpress-dev`, ns `risingwave`, db `dev`** (via port-forward + local psql,
endpoint 10.10.82.50, 2026-08-28):

    source | brand_source_kafka
    mview  | brand_mv_raw
    mview  | brand_mv_flat
    mview  | brand_mv_state
    sinks  | 0        tables | 0        secrets | 15
    workers: meta, compute, frontend, compactor — all RUNNING (1 compute node)
    databases: dev (only)

Those four names appear in **zero files on `origin/master`**. Master's
`pipelines/Brand/` uses `kafka_brand`, `mv_brand`, `mv_brand_state`, `mongo_brands`
and has no `flat` view. Master's Brand is a **rewrite that has never executed
anywhere.**

The live names are on **`origin/f/driver`** (`pipelines/100-Brand/`, Timothy Preble,
last commit **2026-04-28**, 102 commits master does not have). Also found on
`origin/f/cmoone-activeresource` (Cathy Moone, 2026-02-19).

**The two branches hold disjoint halves of the system:**

| | `f/driver` | `master` |
|---|---|---|
| SQL matching live dev | ✅ 44 files, 4 pipelines | ❌ rewrite, never run |
| `build/apply.sh`, `build/Dockerfile` | absent | present |
| `deploy/` overlays | 1 file | 8 files |
| `.github/workflows` | 1 | 6 |
| ships via | `deploy.ps1` / `rw_deploy.ps1` (laptop) | image → ECR → Argo CD |

`f/driver` carries three pipelines master has never seen: `200-ActiveResource`,
`300-Employee`, `400-Driver` (20 files).

## Correction to an earlier claim

⚠️ We said "Tim hardcoded credentials in the SQL and we are abstracting them."
**Backwards for these files.** Counted across `pipelines/*.rw|*.sql` (2026-08-28):

| key | `f/driver` | `master` |
|---|---|---|
| `sasl.password` | 4/4 parameterised | **0/4 — all literal** |
| `sasl.username` | 4/4 parameterised | — |
| `properties.bootstrap.server` | 4/4 parameterised | — |
| `mongodb.url` | 4/7 parameterised | **0/4 — all literal** |
| `%PLACEHOLDER%` total | **69** | 55 |

The literal `mongodb://root:abcd@rw-mongodb:27017/` and the live Confluent
credentials are **master's rewrite**, not Tim's branch. The rewrite regressed
parameterisation Tim already had.

## Population claim (not one sample)

Across all 44 SQL files on `f/driver`: **53 `DROP` statements, 0 `ALTER`.**
Drop-and-recreate is the house style of the whole codebase, not a quirk of Brand.

## `f/tim` is dead

2025-08-22, **0 commits** not already in both master and `f/driver`, none of the live
object names. It is an ancestor. Do not treat it as current.

## Tested and killed

* **`f/tim` as the source of truth** — a year old, nothing unique in it.
* **Making `f/driver` master** — would delete `build/`, `deploy/` and 5 of 6 workflows,
  i.e. the entire delivery path.
* **`psql` inside the RW frontend pod** — `risingwavelabs/risingwave:v2.8.2` has no
  Postgres client. Exec works; the binary is absent. Use a port-forward.
* **Resolving a kubeconfig by `{.clusters[*].cluster.server}`** — returns EVERY server in
  a merged file, so a loop that does not break on first match selects the last one.
  On 2026-08-28 this selected `~/.kube/config` (**prod EKS**) while printing a dev MATCH.

## Traps

* **A `kubectl exec` failure reads as a SQL refusal.** The first probe merged stderr and
  grepped for `ERROR`; eight statements were reported `UNSUPPORTED` when the real cause
  was one missing binary. Fixed by using psql exit codes: 0 ok, 2 cannot connect (abort
  the run), 3 SQL error, 124 hung. **A transport failure must never render as a verdict
  about the system under test.**
* **RisingWave DDL can wedge.** `CREATE TABLE zz_probe_t` hung at **0.0%** in
  `rw_catalog.rw_ddl_progress` (job 130) and then blocked its own name — the catalog
  holds it "under creation" and `DROP TABLE IF EXISTS` says "does not exist, skipping".
  Clear with `CANCEL JOBS <id>;`. ⚠️ **Still outstanding on op-dev as of writing.**
* **The ALTER-vs-DROP question is still unanswered** — the probe never got past the wedge.

## RESOLVED 2026-08-28 — two repos, one canonical

Tim's link pointed at **`usxpressinc/risingwave-poc`**, not `variant-inc/risingwave-pipeline`.
Same repo, forked. Settled by `git ls-remote` + `rev-list --left-right`:

    poc/master  28ea5308   ...   poc-only: 0
    variant/master 310aa151 ...  variant-only: 27
    f/driver    16f9374d   IDENTICAL in both

**`variant-inc/risingwave-pipeline` is canonical** — its master is a strict superset of the
POC's, which is a pure ancestor whose last real content is 2025-09-11 (only a `.gitignore`
tweak since, 2026-01-23). The POC has none of the machinery: no `build/apply.sh`, no
`Dockerfile`, no `smoke/`, 1 deploy file vs 8, 1 workflow vs 6.

Because `f/driver` is the same commit in both, the merge can be done in variant-inc with
nothing lost. ⚠️ The trap avoided: Tim's self-assigned "get master up to date" would have
landed in the POC repo, which **nothing builds from**.

**Tim confirmed `f/driver` is the most up-to-date** and owns bringing master current.

## Also raised 2026-08-28 — SQLMesh

Zach (RisingWave) recommended **SQLMesh** (sqlmesh.readthedocs.io); Tim asked us to evaluate.
The summary he was given claims it is "purpose-built for RisingWave's SQL dialect and
streaming semantics" — that reads as an LLM overstatement; SQLMesh is a general SQL
transformation framework from Tobiko Data. **UNVERIFIED, do not repeat the claim.**
Three questions before it enters any plan:
1. Is there a real RisingWave **engine adapter**, not just compatible SQL?
2. Does it model **continuously maintained** views? SQLMesh thinks in scheduled/incremental
   runs; a RisingWave MV has nothing to "run".
3. What does it do with `CREATE SOURCE` / `CREATE SINK` / `CREATE SECRET` — connectors, not
   models. Expectation: no concept for them.

Scope note: SQLMesh would replace **`apply.sh`** (what SQL to run), not the image/ECR/Argo CD
path (what reaches which cluster). Different halves — say so early or it becomes
"SQLMesh vs our CI/CD".

## Open — needs Tim

1. ~~Is `f/driver` current?~~ **Answered: yes, Tim confirmed 2026-08-28.**
2. ~~Why did it never merge?~~ Not blocked — it is on Tim's own task list.
3. Dev runs **0 sinks** though `400-sink.rw` defines `mongo_brands` — deliberate, or
   dropped and never recreated? (INFRA-1644 has been open on an assumption.)

## Consequence for the QA cutover

"Promote dev's ETL to QA via an image" **does not do that**. An image built from `master`
carries SQL that has never run. The shape of the fix is a **one-directory merge**:
master keeps the machinery, `pipelines/` comes from `f/driver`.

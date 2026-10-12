# QA promotion is blocked, and the cause is in our files — 2026-10-12

Started from "what do we need to put in place so Tim can merge to master freely".
Answer: **nothing on Tim's side.** The work is all on the promotion side, and three of
the findings below were sitting in files we own.

## Tim is not the blocker

`master...f/Brand_Employee` is `ahead 2, behind 7`, and his two commits touch only
`.github/workflows/build-sql-image.yml` and `pipelines/100-Brand/200-ingest.rw`.
`400-sink.rw` is untouched, so GitHub's three-way merge keeps master's
`%MONGODB_CONNECTION_STRING%`. **His merge is safe and needs no preparation.**

⚠️ I claimed the opposite earlier in the day, from a file-content comparison. Comparing
what two branches *contain* does not tell you what a merge *produces*; only the merge
base does. The command that settles it is
`gh api repos/<o>/<r>/compare/<base>...<head> --jq '.files[].filename'` — if the file is
absent from that list, the branch did not change it and the base's version wins.

## The variable contract closes in dev — measured, not inferred

30 distinct `%VAR%` placeholders on master. dev supplies 29 ConfigMap keys
(`etl-pipeline-endpoints`) + 13 Secret keys (`etl-pipeline-credentials`). The five the
SQL uses and dev does not supply — `KAFKA_TOPIC_ENTITY`, `MONGODB_HOST`, `MONGODB_PORT`,
`MONGODB_USERNAME`, `MONGODB_PASSWORD` — appear **only** under `pipelines/Template/`,
which every environment excludes. So every placeholder in the SQL that actually applies
is supplied. First end-to-end confirmation of this.

## QA fails on promotion today

| # | Finding | Severity |
|---|---|---|
| 1 | `apply.sh`'s dead-pattern guard is **aggregate** — "excluded 0 of N". QA's `EXCLUDE_RE` has five alternatives, three live and two dead, so it reports healthy | BLOCKER |
| 2 | QA's `employee` never matches master's `300-Employee` (case), so QA selects the whole Employee pipeline it means to skip | BLOCKER |
| 3 | QA supplies **zero** Employee variables — the only `EMPLOYEE` line in `values-qa.yaml` is the broken `EXCLUDE_RE` itself. So `render()` refuses those files and the hook Job fails, in a log Argo deletes | BLOCKER |
| 4 | `values-prod.yaml` **does not exist**. prod ETL has no values file at all | BLOCKER for prod |
| 5 | QA's `^pipelines/Brand/(300-transform\.sql\|400-sink\.rw)$` clause is dead — those files moved to `100-Brand/` | advisory |
| 6 | QA does not set `EXCLUDE_STRICT`; dev does. Latent only: with `excluded_count > 0` the flag is never consulted | advisory |
| 7 | QA's comment *"apply.sh validates EVERY runtime value before applying EXCLUDE_RE"* is **false** — lines 14-34 are plain `${VAR:-}` defaults, and validation happens per file inside `render()`, after exclusion. This wrong comment is the stated reason `POSTGRES_SERVER`/`POSTGRES_ENTITY_DB` are pinned to `""` | lint, load-bearing |
| 8 | QA's comment *"QA's overlay value, which happens to equal dev's"* is false — QA carries `employee` and the Brand clause; dev carries neither | lint |

Reproduced in `exclude-list/apply-exclusion-block.sh` against master's real tree:
QA's current regex exits **0**, excludes 3 of 9 files and selects both `300-Employee`
files.

## The fix is to stop using a regex

A single regex can only be validated in aggregate. A **list** can be validated per
entry, so `EXCLUDE_PATHS` requires every entry to match at least one discovered file —
`employee  0 file(s)`, named, with a non-zero exit under `EXCLUDE_STRICT=true`. That is
a property the regex form cannot be given, which is why this is a replacement and not a
tightening. `EXCLUDE_RE` stays honoured, with a deprecation warning.

Defaults OFF: warn-only unless `EXCLUDE_STRICT=true`, so it lands without changing any
environment's outcome. dev turns it on first — dev's list is already clean.

## Proven

- Tim's merge cannot revert the Mongo fix (merge-base, not file contents).
- Every placeholder in the applied SQL is supplied in dev, as of 2026-10-12.
- QA's exclusion selects `300-Employee`, and QA has no Employee variables ⇒ the apply
  refuses those files. Verified against master's tree in a harness, exit 0 today.
- `values-prod.yaml` is absent from `deploy/chart` on master.
- The list form names the dead entry and exits 1 under strict; it refuses when
  `EXCLUDE_PATHS` and `EXCLUDE_RE` are both set, and when everything is excluded.

## Tested and killed

- "`pipelines/Brand/` is a duplicate Brand pipeline applied twice" — it holds only
  `README.md`.
- "`^pipelines/...` can never match because the path is absolute" — wrong. `apply.sh:39`
  matches the path **relative to `/pipeline`**, so it begins `pipelines/`. The clause is
  dead for the other reason only.
- "A Type-2 `CREATE SECRET` name is never substituted as an env var" — wrong.
  `MONGODB_USERNAME`/`MONGODB_PASSWORD` are substituted in `shared/000-secrets.rw`,
  which is where the `CREATE SECRET` objects are built.
- "The ETL chart lives in `iaac-risingwave-onprem`" — wrong, twice, costing two 404s.
  It is `variant-inc/risingwave-pipeline`, `deploy/chart`, `master`, `values-dev.yaml`.
  The Argo Application is the authority: read `.spec.source`.

## Traps

- `kubectl -o jsonpath` has no `range $k,$v :=`; use `-o json | jq -r '.data|keys[]'`.
- An empty result from a `gh api … --jq` tree filter prints nothing and looks identical
  to "no matches". It is NOT MEASURED until the ref and the path are confirmed.
- A guard that counts in aggregate cannot see a partially dead pattern. Count **per
  entry**, and print the count beside each entry.

# On-prem ETL delivery — state as of 2026-10-09

## PR ledger

| Repo | PR | What | State |
|---|---|---|---|
| risingwave-pipeline | **#74** | `secret.yaml`: `jq -er` on 11 keys, temp-file `trap`, Teams webhook guard | ✅ merged |
| risingwave-pipeline | **#76** | the `risingwave-etl` Helm chart | ✅ merged |
| iaac-talos-flux-platform `op-dev` | **#173** | dev Application → `deploy/chart` + `values-dev.yaml` | ✅ merged, verified live |
| risingwave-pipeline | **#78** | `values-qa.yaml` (inert) | 🟡 open |
| ix-kafka-topics-users | **#303** | consumer-group grant | ✅ merged 2026-10-09 (jenni-ray + jshaw-usx); **dev deployed, QA NOT** |

## Dev — DONE AND PROVEN END TO END (2026-10-09 16:36Z)

A real change travelled the Helm path and the pipeline produces rows:

| layer | evidence |
|---|---|
| chart change -> Argo | synced to `503a1997`, 16:36:10 -> 16:36:24 |
| hook Job from the CHART's template | `Job/etl-pipeline-apply hookType=Sync hookPhase=Succeeded` |
| change reached the cluster | ExternalSecret `refreshInterval: 55m` |
| `apply.sh` | clean exit |
| **Kafka** | **`mv_brand` = 9 rows** |

The trigger was a deliberate one-line `refreshInterval` nudge in `values-dev.yaml`. It also
exposed that `deploy.yml`'s `paths-ignore` lists `deploy/overlays/**` but not
`deploy/chart/**`, so a values-only change rebuilds the image and cascades into a
`promote-to-qa` run. One-line fix, outstanding.

## Dev — earlier notes

`risingwave-etl` on op-dev sources `deploy/chart` with `values-dev.yaml`. Verified at every
layer: GitRepository `797a56c5` → Kustomization applied `797a56c5` → ApplicationSet carries
the helm block → Application `path=deploy/chart`, Synced/Healthy → **all four objects kept
their resourceVersion**. The render was identical, so Argo had nothing to apply.

**Not yet proven on dev:** the flip changed nothing, so the Helm path has never carried an
actual change. The first real test is a digest bump, where the tracked `etl-pipeline-image`
ConfigMap has to make Argo notice and fire the hook — the mechanism that was silently broken
2026-09-29 → 10-07.

**Also outstanding on dev:** `argocd` Kustomization is referenced by `argocd-apps` but never
declared in the cluster repo (`bm-dev` only; `op-usxpress-qa` and `op-usxpress-prod` both
declare it). A rebuild loses Argo CD. PR deliberately not raised yet — a wrong `path` there
prunes Argo CD's own 8 objects.

And the Application's **last sync operation is `Failed`** (21:47:53Z, the
`GroupAuthorizationFailed` applier run). A failed hook operation makes the next sync return
instantly replaying the old failure, so when the ACL lands this will likely need an explicit
retry rather than a fresh sync.

## QA — FLIPPED TO HELM 2026-10-09 17:50Z

| layer | evidence |
|---|---|
| GitRepository `infra` | `op-qa@sha1:625b1cc9` |
| Kustomization `argocd-apps` | applied `625b1cc9` |
| ApplicationSet | `path=deploy/chart`, `valueFile=values-qa.yaml`, helm block present |
| Application | `path=deploy/chart`, Synced/Healthy |
| all four objects | **resourceVersion unchanged** |

The gate was a render diff with the image digest **normalised out** — 81 fields each side,
identical. The digest had to be excluded because `promote-to-qa` moves it every 10 minutes
on a cron and auto-merges its own PR; a hand-pinned digest in `values-qa.yaml` would have
rolled QA back. risingwave-pipeline#82 makes that workflow write `values-qa.yaml` alongside
the overlay, so both sources carry the same digest and the flip could not regress the image.

**QA's end-to-end proof arrives on its own:** the next promotion writes a new digest into
`values-qa.yaml`, Argo sees tracked drift, and the hook Job fires.

**STILL MISSING ON QA: the Kafka consumer-group grant.** #303 merged and was deployed to
dev only, because the dev deploy gates the PR and nothing gated QA. Until someone deploys
`ix-kafka-topics-users` to the QA environment in Octopus, QA's `mv_brand` keeps failing with
`GroupAuthorizationFailed`.

## QA — earlier notes

`values-qa.yaml` renders byte-identical to `deploy/overlays/qa` (81 fields, sha
`3278343208d37c68`). Three lines differ from dev's: `environment`, `digest`, topic.

**Blocked on:** op-qa unreachable. Both `10.10.82.50` and `.51` time out at TCP while AWS SSO
resolves fine — VPN, not a cluster fault. QA's values are **overlay-derived**, a weaker basis
than dev's live-derived file, and that mattered once already (the hand-written dev file had
drifted from live in five places).

**Open question before the flip:** the overlay says `qa_brand_management_cdc_brand_avro`; a
2026-10-08 note records QA's live ConfigMap deliberately reading **dev's** topic. If live
disagrees, live wins and the topic change is a separate decision with Tim.

## Prod — THREE PRs RAISED, NONE MERGED (2026-10-09)

Prod was never wired. Measured: 0 Applications, 0 ApplicationSets, 0 objects in
`app-risingwave`, while RisingWave itself is fully healthy and the Argo repo credential
already exists and syncs. So this is a first wire-up, not a conversion.

**Merge in this order. The third one turns prod on.**

| # | PR | What | Inert? |
|---|---|---|---|
| 1 | risingwave-pipeline **#84** | `values-prod.yaml` + the `UNVERIFIED_` render guard | yes |
| 2 | iaac-talos-flux-platform **#175** | `argocd-apps` ApplicationSet on `op-prod` | yes |
| 3 | iaac-talos-flux-cluster **#42** | `argocd-apps` Flux Kustomization | **NO — this is the live one** |

When #42 reconciles, prod gets its first Argo Application, four objects appear in
`app-risingwave`, and a Sync hook runs `apply.sh` against production RisingWave.

**Run 1 is a SMOKE run** (`PIPELINE_DIR=/pipeline/smoke`), decided deliberately. It proves
image pull, Kyverno admission, ESO secrets, a writable `/tmp` and in-cluster reach — without
executing Brand DDL, which opens with `DROP SOURCE IF EXISTS kafka_brand CASCADE`.

### Two things prod's values do differently, both deliberate

**`PG_HOST` corrected to `pg-postgresql`.** The old overlay named `postgres-postgresql`,
which does not exist on prod — so that overlay can never have run. Finding 5 was drift, not
a second install.

**Two Kafka keys are `UNVERIFIED_SET_BEFORE_RUN_2` markers.** `apply.sh` validates every
runtime value before applying `EXCLUDE_RE`, so the keys must be non-blank even for smoke.
Prod's real topic is genuinely unknown: topics render as
`<prefix>brand_management_cdc_brand_avro` and `confluent_prefix` is a per-deployment
Terraform variable absent from the repo (dev `dev_`, QA `qa_`, prod set in Octopus). A
plausible-looking wrong topic passes every check and fails at Avro decode —
[[validator-checks-every-value-not-the-selected-ones]]. **The chart now refuses to render if
`PIPELINE_DIR` leaves smoke while any marker remains**, four-way tested and output-neutral
for dev and QA.

### Before merging #84

Re-check the digest against what QA runs. There is **no promote-to-prod automation**;
prod's digest is pinned by hand, and `promote-to-qa` moves QA's every 10 minutes.

## Prod — earlier findings

Never wired. Six findings in `FINDINGS-2026-10-09-prod-etl-never-wired.md`: no `argocd-apps`
on `op-prod`, 3 objects not 4, a 64-zero placeholder digest, `PIPELINE_DIR=/pipeline/smoke`,
a different Postgres release (`postgres-postgresql` / `PG_DB=postgres`), and a dead `PG_USER`
in the ConfigMap. **`values-prod.yaml` deliberately not written** — it would have rendered
identical to that overlay and been wrong six ways.

Two decisions needed: is prod's Postgres a second install or drift, and does prod's first run
stay on the smoke payload.

## Messages drafted, not sent

- `MESSAGE-tim-dev-live-2026-10-08.md` — dev is live, how to deploy, how secrets work
- `MESSAGE-tim-kafka-pr-2026-10-09.md` — what closes #303 and why
- `MESSAGE-confluent-credential-rotation-2026-10-08.md` — needs a recipient list

## #303 — merged, dev deployed, QA outstanding

Jeff Shaw approved and **deployed to dev before the merge** — that deploy is a required
check on the PR, so the order is deploy-then-merge here, not merge-then-deploy
([[octopus-deploy-can-gate-the-pr]]). Merged 2026-10-09.

**QA still needs its own Octopus deploy.** Separate deployment, separate service account.
Unverified whether dev's ACL is actually live — op-dev has been unreachable (VPN) since the
merge, so nothing has been measured at the cluster.

## The one thing blocking data

#303. Until it is approved, merged **and** Octopus-deployed per environment, neither dev nor
QA produces Brand rows regardless of how they are delivered. `CREATE SOURCE` works,
`SELECT … LIMIT 1` works (batch scans use no consumer group), `CREATE MATERIALIZED VIEW`
fails.

## 2026-10-09 evening — Tim's own repo deploys to op-dev, PROVEN

**The cross-org path asked for on 2026-10-07 is delivered.** Tim pushes to `master` in
`usxpressinc/risingwave-poc`; the published reusable workflow
`variant-inc/iaac-risingwave-cicd@v1` builds and pushes `risingwave/poc-pipeline`; op-dev's
chart pulls that digest and Argo's sync hook applies his SQL. No secrets in his repo, no
access to ours, no cross-org token.

| Step | Evidence |
|---|---|
| his build | run 37979835910, `build-sql-image`, all 11 steps success |
| image in ECR | `poc-pipeline@sha256:ac2b1e95…`, pushed 15:23:29, 6,650,344 bytes |
| dev pulls it | ConfigMap `etl-pipeline-image` = `ac2b1e95…` |
| secret complete | `etl-pipeline-credentials` has **10** keys, no partial write |
| scope applied | ConfigMap `PIPELINE_DIR=/pipeline/pipelines/100-Brand` |
| hook ran | `Job/etl-pipeline-apply Sync Succeeded` on revision `ffcca48c` |
| **his SQL is live** | `brand_source_kafka`, `brand_mv_flat/raw/state` in dev's catalog |
| data | `brand_mv_state` = 3 rows |

### PRs merged tonight
| # | What |
|---|---|
| **85** | dev's `image.repository` → `risingwave/poc-pipeline`, digest `ac2b1e95` |
| **86** | 7 Kafka properties into dev's ExternalSecret, 2 constants, `PIPELINE_DIR` scoped |

### The four blockers, in the order they fired
1. **403 on the manifest HEAD** — `poc-pipeline` had no ECR repository policy;
   `etl-pipeline` carries `OnPremClustersPullOnly`. Granted dev's account only.
2. **27 missing runtime values** — `apply.sh` validates every variable in every discovered
   file *before* applying `EXCLUDE_RE`. Narrowing `PIPELINE_DIR` was the lever; widening
   `EXCLUDE_RE` could not have worked.
3. **No Kafka credentials in dev at all** — the ConfigMap had the topic and the Avro subject
   but no bootstrap server, SASL or schema-registry values. All seven live in
   `op-usxpress-dev/risingwave/kafka`.
4. **A wedged failed hook** — the Application sat on `8dc20f6` reporting
   `phase=Failed` with the previous run's message. A `refresh=hard` annotation moved it.

### Proven
- Tim's repo → ECR → op-dev, end to end, verified by a RENAMED object and not by a row count.
- `apply.sh` can create a Kafka-connected source. **This had never been shown.** Dev's older
  Brand sources came from the `pipeline.yaml` psql path, which takes its environment from
  GitHub secrets — the chart path had only ever run the smoke payload.
- The chart generating the Job's env from `externalSecret.data` held up: seven keys added in
  one place, no second list to drift.

### Tested and killed
- *"The pull secret is seven weeks stale and every prior pull was a cache hit."* False —
  `cronjob/ecr-credentials-sync` runs `0 */6 * * *`. A Secret's `creationTimestamp` is not
  the age of its data.
- *"`EXCLUDE_RE` blocks `employee`, so Tim's tree is filtered out."* False — his directory is
  `300-Employee`, capital E; the lowercase pattern never matched it.
- *"`mv_brand` = 9 proves the apply worked."* It proves nothing: 9 and 3 were already
  recorded on 2026-08-28 and his drop-and-recreate rebuilds to the same numbers.

### Traps
- **`kubectl --context "$C"` with `$C` empty silently uses the CURRENT context.** A
  `grep -i dev` over `get-contexts` matched nothing, and four queries intended for op-dev ran
  against **qa-one** EKS, reporting `namespaces "app-risingwave" not found` as if about dev.
  op-dev is not in the default kubeconfig at all — it is
  `~/.kube/op-usxpress-dev-fresh.yaml`, endpoint `10.10.82.50:6443`.
- **`rw_catalog.rw_relations` has no timestamp column** (id, name, relation_type, schema_id,
  owner, acl, definition). `created_at` errors. Provenance comes from `definition` or from a
  name only the new code uses.
- **`select … from rw_catalog.rw_relations order by id desc` returned zero output twice**,
  no error, while `show sources` / `show materialized views` worked. Unexplained; prefer the
  `show` forms.
- **Argo deletes the hook Job on success as well as failure**, so `kubectl logs job/...`
  returns NotFound either way. `.status.operationState.syncResult.resources` is the record.

### Open, each with a known shape
| Item | What it needs |
|---|---|
| Employee pipeline | the real `KAFKA_TOPIC_EMPLOYEE` — only Tim can name it |
| Mongo sinks | `MONGODB_HOST`/`MONGODB_PORT`; the dev secret holds `MONGODB_CONNECTION_STRING` |
| Postgres CDC | `wal_level=logical` (iaac-risingwave-onprem#41) + a real entity DB; `POSTGRES_SERVER` and `POSTGRES_ENTITY_DB` are empty strings |
| ECR policy drift | set by CLI tonight; import into Terraform beside the 3 hand-made untagged roles |
| SQL duplication | his repo has 3 SQL trees, ours has more; QA runs a transform absent from his. Undecided |

## 2026-10-09 late — dev runs Tim's FULL Employee pipeline, end to end

Kafka -> RisingWave -> materialized view -> sink -> relational tables, from
`usxpressinc/risingwave-poc`'s own image. Counts agree at every stage:

| Stage | Count |
|---|---|
| `rw_employees1` / `rw_employee_contacts1` (RW tables from Kafka) | 2 / 1 |
| `employees_master_mv_flat` / `employees_home_master_mv_flat` | 2 / 1 |
| `employee.employees` / `employee.employee_contacts` in Postgres `entities` | 2 / 1 |
| `brand_mv_state` | 3 |

Live objects: sources `employees_source_kafka` + `pg_employees_source`, sinks
`pg_employees` + `pg_employee_contacts`, and replication slot `rw_employee_slot`
(`pgoutput`, database `entities`, **active = t**). The active slot is the only direct
evidence that CDC runs; no status field shows it.

Topic: **`dev_timmyp_cdc_employee_json`** — JSON, not Avro, which is why his Employee
source needs no schema-registry variables. Read from the Confluent REST API, not guessed.

### PRs merged
| # | What |
|---|---|
| **87** | `PIPELINE_DIR` widened to `pipelines/`, the employee topic, Postgres entity + CDC values, 2 secret entries |
| **88** | `POSTGRES_ENTITY_DB` = `entities`, not `rw_entity` |

### ⚠️ DRIFT created out of band on op-dev — all of this needs codifying
| Thing | Where it lives now | Should be |
|---|---|---|
| database `entities`, owner `rw_entity_app` | created by psql | his `000-init-db-entities.sh`, or Terraform |
| role `rw_entity_app` WITH `REPLICATION` | created by psql | Terraform |
| schema `employee`, publication `rw_employee_pub FOR ALL TABLES` | created by psql | as above |
| `wal_level=logical` | `ALTER SYSTEM` -> `postgresql.auto.conf` on the PVC | iaac-risingwave-onprem#41 |
| `op-usxpress-dev/risingwave/entity` | `aws secretsmanager create-secret` | Terraform |
| ECR policy on `risingwave/poc-pipeline` | `aws ecr set-repository-policy` | `gha-oidc-trust.tf`, with `import` |

`ALTER SYSTEM` survives a pod restart because it writes to the data volume, so #41 is
now a tidy-up rather than a blocker — but until it merges, a PVC rebuild loses CDC.

### Proven
- Tim's repo -> ECR -> op-dev -> RisingWave -> Postgres, with his Employee SQL.
- `apply.sh`'s app-database guard works: `.sql` goes to `POSTGRES_ENTITY_*`, and it refuses
  outright when the app database equals the RW meta store (same host is fine, same database
  is not). His tables could not have landed in `risingwave_meta` by accident.
- A Postgres restart of `postgres-postgresql` cost RisingWave one meta restart and one
  operator restart; everything came back Ready with no crash loop.

### Tested and killed
- *"A failed file is marked applied — `applied 0, skipped 10` proves a ledger defect."*
  **FALSE.** The ledger (`pipeline_applied`, keyed on path + sha256) is written only after a
  successful apply. Argo's own sync hook had applied everything between my two debug runs,
  once the stuck DDL job cleared. **A `skip` is not evidence that a file failed** — check
  whether another runner did the work before calling it a defect.
- *"`risingwave` can do the setup."* It has `createdb` only. `ALTER SYSTEM`, the
  `REPLICATION` attribute and `CREATE PUBLICATION FOR ALL TABLES` all need superuser.

### Traps
- **`psql -c` does NOT interpolate `:'var'`.** Variable substitution happens only for input
  read from a file or stdin, so `-c "... PASSWORD :'ep'"` is a syntax error at the colon.
  Pipe the statement in instead: `printf "... PASSWORD '%s';\n" "$P" | psql ...` — which also
  keeps the credential out of argv.
- **A `\c <db>` inside an applied `.sql` overrides the configured database.**
  `001-create_rdms_tables.sql:21` is a literal `\c entities`, so `POSTGRES_ENTITY_DB` is
  decorative for that file and the database name is fixed in his SQL. The failure reads
  `database "entities" does not exist` and looks like a config error.
- **`ALTER SYSTEM` leaves `pending_restart = false` until the config is re-read.** Run
  `select pg_reload_conf();` before believing `pg_settings`, or a landed change looks absent.
- **The Bitnami objects disagree on name:** Helm release `postgres`, StatefulSet
  `postgres-postgresql`, Service `pg-postgresql`. The superuser password is
  `pg-credentials/password` — the SAME key the app user uses, since
  `POSTGRES_PASSWORD` and `POSTGRES_POSTGRES_PASSWORD` both reference it.
- **PostgreSQL 15+ stopped granting `CREATE` on `public`**, so a new owner needs
  `ALTER SCHEMA public OWNER TO <role>` or his `CREATE TABLE` fails on a server that looks
  configured correctly.
- **A stuck `creating` streaming job blocks an unrelated `DROP`** with
  `can not drop 1 creating streaming job`. It cleared on its own here; `rw_ddl_progress`
  was empty by the time we looked, and `CANCEL JOBS` was never needed.

### Still open
| Item | What it needs |
|---|---|
| Mongo sinks (`400-sink.rw`, `999-downstream_sinks.rw`) | dev holds `mongodb+srv://…mongodb.net/` with **no port**; his SQL builds `mongodb://user:pass@host:port`. A change in HIS repo, not config |
| All six drift rows above | Terraform, with `import` where the object already exists |
| QA and prod | untouched and still on `etl-pipeline`; nothing here was promoted |

## 2026-10-09 night — the promotion chain exists and is verified inert

`promote.yml` + `apps.json` merged as **PR #89**. One digest moves ECR -> dev -> QA -> prod
and nothing is rebuilt between environments.

| Environment | Source | Merge |
|---|---|---|
| dev | newest digest in the app's ECR repository | automatic |
| qa | the digest `values-dev.yaml` already runs | automatic |
| prod | the digest `values-qa.yaml` already runs | **human** |

Each environment's source is the one before it, so **QA can only receive something dev has
actually run**. The old `promote-to-qa.yml` went straight from ECR to QA with dev never
seeing the image; it is left in place and untouched, because retiring it while dev points at
`poc-pipeline` would stop QA receiving `etl-pipeline` images. That retirement waits for a
real dev -> QA promotion through the new path.

### Verified by dispatch, run 37991163723
```
risingwave-etl/dev:  already on sha256:ac2b1e958e9b (from ECR risingwave/poc-pipeline)
risingwave-etl/qa:   not in the promote list, skipping
risingwave-etl/prod: not in the promote list, skipping
```
The dev line proves the role reads `poc-pipeline`, `apps.json` parses, the values file
resolves and the repository guard passes. The qa and prod lines prove the **safety gate**:
`apps.json`'s `promote` list is `["dev"]`, so merging this could not touch QA or prod.

⚠️ **The sed-and-PR half is still untested.** Dev is already on the newest digest, so the
workflow has only ever taken the no-op path. Its first real exercise is Tim's next push, and
that is the right first test rather than a synthetic one.

### Guards in the workflow, and why each exists
| Guard | Failure it prevents |
|---|---|
| target values file must already `repository:` the app's own ECR repo | a digest from one repo written into a file pointing at another — the pod then cannot pull something that genuinely does not exist |
| `grep` the digest back after the `sed` | a silent sed miss reporting success and changing nothing |
| `promote` list in `apps.json`, not in the workflow | a new environment going live on a merge nobody read as a deploy |
| job-level `if` on `workflow_run.conclusion` | a failed build promoting anything |
| prod opens a PR and does not merge | production moving without a person |

### No new identity
Reuses `gha-risingwave-etl-ecr-push`, whose trust already covers this repo on `master`. Its
inline `ecr-push` policy was extended to list `risingwave/poc-pipeline` beside
`risingwave/etl-pipeline` — **drift, same list as the ECR repository policy.**

### ⚠️ Found while testing
Merging #89 triggered a **`deploy`** run, because `apps.json` and `.github/workflows/**` are
not in `deploy.yml`'s `paths-ignore`. Every workflow edit therefore rebuilds the
`etl-pipeline` image and then fires `promote` through `workflow_run`. Harmless but wasteful;
two lines fix it, to be folded in with the stale `POSTGRES_SERVER` comment.

## 2026-10-09 night — the Mongo question is answered

**`mongodb+srv` works.** `CREATE SINK` with the Atlas SRV string succeeded on dev
(RisingWave 2.8.2), the sink appeared, `rw_ddl_progress` stayed empty and the compute log
logged nothing. The documentation never mentions SRV, so this had to be measured.

⚠️ `getent hosts <cluster>.mongodb.net` returning nothing is **expected** — an SRV-only name
has no A record and `getent` cannot query SRV. That is not a DNS failure.

**So the Mongo fix is one line in HIS repo**, in `400-sink.rw` and `999-downstream_sinks.rw`:

    mongodb.url = '%MONGODB_CONNECTION_STRING%'

replacing `mongodb://%MONGODB_USERNAME%:%MONGODB_PASSWORD%@%MONGODB_HOST%:%MONGODB_PORT%/`,
because an SRV string has no port to supply. Our side is then one `externalSecret.data`
entry for `MONGODB_CONNECTION_STRING` and dropping the two files from `EXCLUDE_RE`.

Also learned: a sink from any MV with `type='append-only'` fails until
`force_append_only='true'` is set, because an MV is a retract stream — and that option drops
DELETEs and converts UPDATEs to INSERTs, so it is a data decision, not a syntax fix.
Detail in [[risingwave-mongodb-sink-facts]].

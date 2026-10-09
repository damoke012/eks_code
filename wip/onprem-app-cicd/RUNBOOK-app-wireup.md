# Runbook — wiring an app repo to an on-prem Argo CD environment

Written 2026-10-09 from the RisingWave ETL wire-up on `op-usxpress-dev`. The procedure is in
`.claude/skills/onprem-app-wireup/SKILL.md`; the check is
`scripts/onprem-app-wireup-check.sh <env>`. This file is the account — what happened, in
order, with the evidence — so the next environment or application is a re-run and not a
rediscovery.

## The shape of the problem

Delivery is a **relay of nine handoffs**, each owned by a different system. On 2026-10-09
every one of them was broken and every one reported success. **Eight green ticks, zero rows,
three weeks.** No single failure was hard to fix; finding which of nine silent handoffs had
failed was the whole cost.

| # | Handoff | How it failed here | What it looked like |
|---|---|---|---|
| 1 | developer → a repo that deploys | pushing to `usxpressinc/risingwave-poc`, an ancestor copy with 1 workflow vs our 6 | ✓ green, from a dead cloud-Octopus workflow |
| 2 | app repo → the published build workflow | the caller PR (`poc#5`) sat **open** | no build at all |
| 3 | build → registry | fine once #5 merged | — |
| 4 | registry → cluster pull | **new ECR repo had NO repository policy** | `ImagePullBackOff`, `403` on the manifest HEAD |
| 5 | registry → the environment's values | **nothing copied the digest across** | everything green, Argo correctly idle |
| 6 | values → runtime config | credentials were IN Secrets Manager and never wired | `ERROR: required runtime values are missing` |
| 7 | applier → the files it should apply | `EXCLUDE_RE` matched **nothing** | a demand for 27 values incl. systems we lack |
| 8 | SQL → the systems it reads | no entity DB, no publication, `wal_level=replica` | `database "entities" does not exist` |
| 9 | consumer → the data | Kafka group grant was a separate repo + deploy | ✓ sync, ✓ hook, **0 rows** |

## Order of operations that worked

1. **`poc#5`** merged → his repo builds its own image via
   `variant-inc/iaac-risingwave-cicd/.github/workflows/sql-pipeline-build-push.yml@v1`.
   No secrets in the app repo; OIDC only.
2. **ECR repository policy** on the new repo, dev's account only
   (`ecr:BatchGetImage`, `GetDownloadUrlForLayer`, `BatchCheckLayerAvailability`).
3. **`pipeline#85`** — `image.repository` **and** `image.digest` in `values-dev.yaml`.
   Both, not one.
4. **`pipeline#86`** — the 7 Kafka properties from `op-usxpress-dev/risingwave/kafka` into
   the ExternalSecret, plus `KAFKA_SASL_MECHANISM=PLAIN` and
   `KAFKA_SECURITY_PROTOCOL=SASL_SSL` as config constants.
5. **Postgres, by hand** — `entities` database owned by `rw_entity_app`, that role with
   `REPLICATION`, schema `employee`, publication `rw_employee_pub FOR ALL TABLES`,
   `ALTER SYSTEM SET wal_level='logical'` and a restart of `postgres-postgresql`.
6. **`pipeline#87`/`#88`** — the Postgres entity and CDC values, the employee topic, and the
   database name corrected to `entities` (hardcoded in his SQL as `\c entities`).
7. **`pipeline#89`** — `promote.yml` + `apps.json`: the missing handoff, registry → dev → QA
   → prod on one digest.
8. **`poc#11`** — both Mongo sinks take `%MONGODB_CONNECTION_STRING%`.
9. **`pipeline#91`/`#93`** — the Mongo credential wired, then the two sinks taken off the
   exclusion list as their own commit.

## Doing this for QA or prod

Do not assume parity. Run `bash scripts/onprem-app-wireup-check.sh qa` first; dev↔QA has
never been two of the same thing. Specifically for QA today:

* The **Kafka consumer-group grant does not exist.** `ix-kafka-topics-users` was deployed to
  **dev only**, because the dev deploy gates that PR and nothing gated QA. QA's materialized
  views will stay empty until someone deploys that repo to the QA environment in Octopus.
  No code change; it needs a person with Octopus access.
* QA still points at `risingwave/etl-pipeline`, not the app's repository, so gate 5's guard
  will correctly refuse to promote until `image.repository` changes.
* `apps.json`'s `promote` list is `["dev"]`. Adding `"qa"` is the deliberate act that makes
  QA live. It is data, not code, on purpose.
* Prod's Postgres is a **different release** — `postgres-postgresql` vs dev/QA's
  `pg-postgresql`, and `PG_DB=postgres` vs `risingwave`. Confirm against prod before copying
  any value.

## Proven

* **Dev runs the app's full pipeline from the app's own repo**, 2026-10-09: Kafka →
  RisingWave → materialized views → sinks → relational tables, plus two Mongo sinks. Four
  sinks live, replication slot `rw_employee_slot` **active**, counts agreeing at every stage
  (2 employees / 1 contact in the RW tables, the MVs, and Postgres `entities.employee.*`).
* **The promotion chain promotes without a human editing a file** — PRs #90 and #92 were
  opened *and* merged by the workflow. Both were human-**dispatched**, so the `*/10` cron has
  still never been the thing that noticed.
* **`apply.sh`'s app-database guard works**: it refuses when the application database equals
  the RisingWave meta store (same host is allowed, same database is not), so application
  tables cannot land in `risingwave_meta` by accident.
* **Cross-org reusable workflows work** from `usxpressinc` into `variant-inc`, OIDC only, no
  repo keys — the thing the whole three-week org debate was about.
* **RisingWave 2.8.2 accepts `mongodb+srv://`** (measured; the docs never say).

## Tested and killed

* *"A failed file is marked applied — `applied 0, skipped 10` proves a ledger defect."*
  **False.** `pipeline_applied` is written only after a successful apply. Argo's own hook had
  done the work between two debug runs. **A skip is not evidence a file failed.**
* *"`apply.sh` validates every value before applying `EXCLUDE_RE`."* **False**, and I wrote
  it the same night. Exclusions are respected; the 27-value error came from a regex matching
  nothing.
* *"The promote workflow created a PR and lost a race against the Wiz checks."* **False** —
  no PR existed. The image simply post-dated the last promote run.
* *"The pull secret is seven weeks stale, so every prior pull was a cache hit."* **False** —
  `cronjob/ecr-credentials-sync` runs `0 */6 * * *`.
* *"There is no MongoDB in dev."* **False** — `op-usxpress-dev/risingwave/mongodb` exists.
  The gap was the credential's *shape*, not its absence.
* *"`risingwave` can do the Postgres setup."* It has `createdb` only; `ALTER SYSTEM`,
  `REPLICATION` and `CREATE PUBLICATION FOR ALL TABLES` all need superuser.
* *"INFRA-1501 — dev's Postgres is not in source."* **Stale.** It is, at
  `manifests/op-usxpress-dev/postgres-helmrelease.yaml`. Close the ticket.

## Traps

* **A row count cannot prove an apply ran.** Drop-and-recreate SQL rebuilds to the same
  numbers from the same source — `brand_mv_raw=9, brand_mv_state=3` were recorded on
  2026-08-28 and again tonight. **Use an object the new code renames.**
* **Argo deletes a sync-hook Job on success as well as failure**, so `kubectl logs job/...`
  is `NotFound` either way. Durable record: `operationState.syncResult.resources`. To read a
  failure, re-run the **same digest** as a plain Job under its own name.
* **`kubectl --context "$C"` with `$C` empty uses the CURRENT context.** A `grep -i dev` over
  `get-contexts` matched nothing and sent four op-dev queries to **qa-one EKS**. op-dev is
  not in the default kubeconfig at all.
* **`psql -c` does not interpolate `:'var'`** — only file/stdin input does. Pipe the
  statement in; it also keeps the credential out of `argv`.
* **`ALTER SYSTEM` leaves `pending_restart=false`** until `pg_reload_conf()`. A landed change
  looks absent.
* **PostgreSQL 15+ stopped granting `CREATE` on `public`** — a new owner needs
  `ALTER SCHEMA public OWNER TO <role>` or `CREATE TABLE` fails on a correct-looking server.
* **The Bitnami objects disagree on name**: release `postgres`, StatefulSet
  `postgres-postgresql`, Service `pg-postgresql`. Superuser password is
  `pg-credentials/password` — the same key the app user uses.
* **A stuck `creating` streaming job blocks an unrelated `DROP`** with
  `can not drop 1 creating streaming job`. Check `rw_catalog.rw_relations`… it has **no
  timestamp column**, so provenance comes from `definition` or a renamed object.
* **Editing an already-applied file is refused**, not re-run: `apply.sh` compares a sha256
  and says *"already applied with a different hash"*. The two Mongo sinks were safe to edit
  only because they had never run.
* **A `*/10` cron is not a guarantee.** Both successful promotions were dispatched by hand.

## Not verified

**Nobody has read the Atlas collections.** The Mongo sinks started and the compute log is
clean — a rejected write logs loudly — but that is not a row count in `rw_dev.brands`.

## Drift created, and where it belongs

| Thing | Belongs in |
|---|---|
| `wal_level=logical` | `manifests/op-usxpress-dev/postgres-helmrelease.yaml`, `primary.extendedConfiguration`. ⚠️ PR #41 was **CLOSED** for touching all three environments; dev-only is safe because that directory is per-environment |
| `entities` DB, role, schema, publication | a documented bootstrap step. Bitnami `initdb.scripts` runs only on an **empty** volume, so it would be inert today |
| `op-usxpress-dev/risingwave/entity` | `deploy/terraform/secrets.tf`, same `random_password` + `ignore_changes` shape as `postgres`. ⚠️ needs a one-time `terraform import` or apply **rotates a live password** |
| ECR repository policy + the `ecr-push` IAM policy | unresolved — that account is not in this repo's Terraform. Guessing the owner is how a live role gets deleted |

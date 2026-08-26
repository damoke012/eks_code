# `variant-inc/risingwave-pipeline` — review, 2026-08-26

Read from a clone at `/workspaces/eks_code/risingwave-pipeline` (gitignored — this repo
pushes to personal GitHub, rule 10). HEAD `310aa15`, branch `master`.

Eight defects. Four block work that is on the board; two are live risks today.

---

## 1. `pipelines/Brand/100-sources.rw` cannot be applied by any mechanism

Idris's INFRA-1637 rewrite (2026-08-26) replaced the inlined Confluent credentials with
`secret` references — correct, and it also left three `%VAR%` placeholders:

| line | placeholder |
|---|---|
| 36 | `%KAFKA_TOPIC_BRAND%` |
| 43 | `%KAFKA_STARTUP_MODE%` |
| 46 | `%KAFKA_SCHEMA_REGISTRY_MESSAGE%` |

`.github/workflows/secret.yaml` is the repo's only substituter. It seds **13** names into
**one** file (`/tmp/000-secrets-populated.rw`):

```
KAFKA_API_KEY  KAFKA_API_SECRET  KAFKA_BOOTSTRAP_SERVER  KAFKA_GROUP_ID_PREFIX
KAFKA_RESOURCE_ID  KAFKA_REST_ENDPOINT  KAFKA_SCHEMA_REGISTRY_API_KEY
KAFKA_SCHEMA_REGISTRY_API_SECRET  KAFKA_SCHEMA_REGISTRY_ENDPOINT  KAFKA_SERVICE_ACCOUNT
MONGODB_CONNECTION_STRING  MONGODB_PASSWORD  MONGODB_USERNAME
```

**None of the three is in that list.** `pipeline.yaml`'s execute step pipes files straight to
`psql`; `build/apply.sh` has no substitution at all. So the file would send
`topic = '%KAFKA_TOPIC_BRAND%'` to RisingWave on either path.

The fix is not a criticism of the rewrite — the substitution layer for *non-secret* values
simply does not exist. It has to be added to `apply.sh` (and to `pipeline.yaml`), or those
three values have to become RisingWave `SECRET`s like the rest.

**Blocks INFRA-1635 and INFRA-1637's deployment.**

## 2. Directory ordering is inverted

`apply.sh` uses `shopt -s globstar` + `sort` on full paths, so with
`PIPELINE_DIR=/pipeline/pipelines` the order is:

```
pipelines/Brand/100-sources.rw      ← first
pipelines/Brand/200-ingest.rw
...
pipelines/shared/000-secrets.rw     ← near last
```

But `Brand/100-sources.rw` says: *"Run `pipelines/shared/000-secrets.rw` first to ensure
secrets exist before recreating this source."* The numeric prefixes order files **within** a
directory; nothing orders the directories, and `Brand` < `shared` in every collation.

⚠️ **Correction to an earlier claim.** I said `apply.sh` used `find -maxdepth 1` and could
only ever apply one directory. That was the stale `wip/onprem-app-cicd/app-template/` copy.
The shipped script is recursive. Rule 7, again.

## 3. The old Confluent credentials are still in git history

```
be70d66  feat(pipelines): Add employee and secret_manager pipelines with PostgreSQL and MongoDB integration
```

still contains `properties.sasl.password = '…'`. Removing them from the working tree does not
unpublish them. **INFRA-1637's second half — revoke, not rotate — is confirmed open.**
Also flagged in the tree: `pipelines/Template/README.md`.

## 4. The prod overlay will fail on its first sync

`deploy/base/externalsecret.yaml` defines three entries: `RW_PASSWORD`, `PG_PASSWORD`,
`PG_USER`.

| overlay | patches |
|---|---|
| qa | `/spec/data/0`, `/1`, `/2` |
| **prod** | `/spec/data/0`, `/1` — **`/2` missing** |

Prod's `PG_USER` therefore keeps `key: PLACEHOLDER/risingwave/postgres`, the ExternalSecret
never syncs, and the Job cannot start. Prod also still carries the pre-fix QA values —
`PG_HOST: postgres-postgresql` (QA learned it is `pg-postgresql`, 03c68f3) and
`PG_DB: postgres` (QA learned it is `risingwave`, d5a07b5). Prod's overlay is a copy of QA's
from before three fixes landed. See [[manifests-copied-across-branches]].

## 5. `pipeline.yaml`'s guardrail blocks five of the repo's own files

It refuses `DROP (TABLE|DATABASE|SCHEMA|VIEW|MATERIALIZED VIEW|SEQUENCE|INDEX|TYPE|FUNCTION|PROCEDURE)`:

| file | why it is blocked |
|---|---|
| `Brand/200-ingest.rw` | `DROP MATERIALIZED VIEW IF EXISTS mv_brand cascade` ×2 |
| `employee/001-create_rdms_tables.sql` | `DROP TABLE … CASCADE` ×2 |
| `employee/102-create_rw_tables.rw` | `DROP TABLE` ×2 |
| `employee/120-transform.rw` | `DROP MATERIALIZED VIEW` |
| `shared/000-audit-setup.rw` | `DROP TABLE … CASCADE` ×4 |

Today's merge passed validate only because it touched `100-sources.rw` and `100-Sources.rw`,
which use `DROP SOURCE` — not on the list. **The guardrail cannot let this repo's own
pipelines through.** It only fires on *changed* files, so it looks fine until someone edits
an ingest or transform file.

## 6. And it misses the destructive statements that matter here

Not caught, 30+ occurrences: `DROP SOURCE`, `DROP SINK`, `DROP SECRET`, `DROP USER`,
`DROP ROLE`. Including all 15 `DROP SECRET` lines in `shared/000-secrets.rw` and
`DROP USER IF EXISTS manager_user`.

The risk is inverted. `DROP MATERIALIZED VIEW … IF EXISTS` is the **safe, normal** way to
iterate on RisingWave DDL — it is blocked. Dropping a source, a sink, every Kafka secret, or
a database user passes silently.

## 7. Postgres-only SQL is wearing a `.rw` extension

`apply.sh` routes `*.rw` → RisingWave:4567 and `*.sql` → Postgres:5432.

| file | postgres-only construct lines |
|---|---|
| `shared/002-audit-triggers.rw` | 40 |
| `shared/000-audit-setup.rw` | 14 |
| `shared/001-manager-user-access.rw` | 1 |

`CREATE TRIGGER`, `RETURNS TRIGGER`, `$$`-quoted bodies, `DECLARE`, `EXECUTE FORMAT`.
RisingWave has none of these. Sent to port 4567 they fail; they belong on 5432 as `.sql`.

## 8. Three GRANTs target a database called `materialize`

`shared/001-manager-user-access.rw:143-145`:

```sql
GRANT USAGE ON ALL SECRETS IN DATABASE materialize TO manager_user;
GRANT CREATE SECRET ON DATABASE materialize TO manager_user;
GRANT DROP SECRET  ON DATABASE materialize TO manager_user;
```

`materialize` is a different product. RisingWave's database here is `dev`. These grants
target a database that does not exist on any of our clusters.

⚠️ **Live now:** run `32981468163` (`Deploy RisingWave User Access with Auditing`) has been
parked at its `approve` gate for five hours awaiting a reviewer, and it applies this file
and rotates `manager_user`'s password. Do not approve it until §7 and §8 are resolved.

---

## Proven

* `Brand/100-sources.rw` carries three placeholders no substituter handles (§1).
* `apply.sh` is recursive; `Brand` sorts before `shared`, inverting a stated dependency (§2).
* Commit `be70d66` still contains the plaintext Confluent password (§3).
* Prod's overlay omits the `/spec/data/2` patch and carries three superseded QA values (§4).
* The guardrail blocks 5 in-repo files and misses `DROP SOURCE|SINK|SECRET|USER|ROLE` (§5, §6).
* Three `shared/*.rw` files contain PL/pgSQL and triggers (§7).

## Tested and killed

* ~~"`apply.sh` uses `find -maxdepth 1`, so only one directory can ever be applied."~~ False —
  read from the stale `wip/` template. The shipped script uses `globstar` and is recursive.
* ~~"Nothing depends on the ARC runner, so INFRA-1644 is a formality."~~ False —
  `pipeline.yaml`'s execute job is `runs-on: risingwave-pipeline`. Retiring the runner breaks
  Idris's dev path. It remains a real decision.
* ~~"The 4-hour user-access run is hung."~~ It is parked at an approval gate, `validate ✓ 8s`.

## Traps

* **A guardrail that only inspects changed files is not a guardrail on the repo.** Five files
  would be refused today; nobody knows, because nobody has edited them since it was written.
* **File extension is a routing decision.** `.rw` vs `.sql` picks which engine receives the
  statements. A Postgres file named `.rw` is not a style problem, it is a wrong destination.
* **A "fix" commit does not unpublish a pushed secret.** Rotation is not revocation.
* **Two workflows fire on the same push** (`pipeline.yaml` and `build-and-push.yml`, both on
  `pipelines/**`), applying SQL to dev and building a QA image from one commit. Neither knows
  about the other.

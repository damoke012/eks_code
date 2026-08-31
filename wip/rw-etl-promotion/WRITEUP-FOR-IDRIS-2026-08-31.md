# Environment-specific values in the RisingWave pipeline — the two designs, and a recommendation

Idris — as promised. This is the write-up on how I've been handling secrets, topics and
per-environment values, so you can compare it against yours and call it.

I want to be straight about one thing up front: **you built the first working version of
this and I built a second one without realising.** Neither of us was wrong; we were solving
the same problem three months apart. This document is the comparison, not a pitch.

---

## 1. What is actually in the repo today

Both mechanisms are on `master` right now. Commit history:

| Path | Author | First | Last |
|---|---|---|---|
| `.github/workflows/secret.yaml` | **Idris** | 2026-05-27 | 2026-06-05 |
| `.github/workflows/pipeline.yaml` | **Idris** | 2026-05-21 | 2026-05-27 |
| `pipelines/shared/000-secrets.rw` | **Idris** | 2026-05-27 | 2026-06-03 |
| `build/apply.sh`, `build/Dockerfile` | **dare-x** | 2026-08-18 | — |
| `deploy/overlays/*`, `deploy/base/externalsecret.yaml` | **dare-x** | 2026-08-18 | 2026-08-20 |
| `.github/workflows/build-and-push.yml` | **dare-x** | 2026-08-18 | — |

There is also duplication *inside* the older half: `secret.yaml` (a workflow) and
`pipelines/shared/000-secrets.rw` (a file) create the **same 15 RisingWave secrets** by two
different routes.

---

## 2. What we already agree on

Worth stating so the argument stays small. We agree on:

* one image, built once, pushed to ECR **by digest**
* promoted unchanged to QA and prod
* Argo CD deploys it; a Job applies the SQL in-cluster
* **the only difference between environments is the values**
* both designs read the same AWS Secrets Manager, per account

That is not in dispute and does not change.

---

## 3. The one real decision — and it is smaller than it looks

The instinct is to frame this as "your design vs mine". It is not. **Yours is a consumer of
mine.** Look at what your own `shared/000-secrets.rw` does:

```sql
CREATE SECRET kafka_api_key WITH ( backend = 'meta' ) AS '%KAFKA_API_KEY%';
```

That single line is both mechanisms. The `%KAFKA_API_KEY%` is the renderer filling a blank
from the ConfigMap/Secret chain; the `CREATE SECRET` is your object. Your design **needs**
the delivery path to get the value in.

So there are three layers, and only the last one is actually in question:

```
Secrets Manager -> External Secrets -> env var -> render()     <- REQUIRED either way
                                          |
                    +---------------------+---------------------+
                    |                                           |
       CREATE SECRET kafka_api_key                straight into the source
       (hidden; needs premium licence)            (visible; no licence)
                    |                                           |
       properties.sasl.password =                properties.sasl.password =
             secret kafka_api_key                    '%KAFKA_SASL_PASSWORD%'
```

**The delivery path is not optional.** Topics, hosts, database names and CDC slots have
nowhere else to live — `secret.yaml` has no slot for a Kafka topic name, and
`deploy/overlays/qa/endpoints.yaml` has no Kafka keys at all today because QA has only ever
deployed the `smoke/` payload.

**Your last hop is the more secure one** and is where we should end up:

| | `CREATE SECRET` (yours) | inline placeholder |
|---|---|---|
| Credential in `SHOW CREATE SOURCE` | **hidden** | **visible** |
| Premium licence | **required** | not required |
| Works with Tim's 44 files as written | no | yes |

---

## 4. Recommendation: a sequence, not a winner

**Step 1 — ship apply-time now.** Unblocked today, licence-independent, proves the whole path
end to end with real DDL.

**Step 2 — convert to `CREATE SECRET` when the licence lands.** And note what that change
actually is: **an edit to Tim's SQL, not to the delivery path.** Nothing in `build/`,
`deploy/` or the workflows changes. The renderer keeps feeding the values in; the SQL stops
consuming them directly and starts consuming secret objects.

Three reasons for that order, in weight:

**(a) Tim's tree does not use `secret <name>` at all.** `f/driver` — the branch actually
running on op-dev, which Tim confirmed is current and is merging to master — writes:

```sql
properties.sasl.password  = '%KAFKA_SASL_PASSWORD%',
schema.registry.password  = '%KAFKA_SCHEMA_REGISTRY_PASSWORD%'
```

Across all 44 of his SQL files there are **zero** `secret <name>` references. Going
`CREATE SECRET`-first means editing all 44 before anything can run.

**(b) It takes the premium licence off the critical path.** You have been blocked waiting for
the key because `CREATE SECRET` is gated. Tim's SQL never calls it. We can test this week.

**(c) Non-secret values need a home regardless**, and that is the ConfigMap. That work has to
happen whichever hop we pick.

### Reducing the exposure in the meantime

The credential is readable by anyone who can run `SHOW CREATE SOURCE` on that cluster. So the
control is **who has RisingWave access** — today `root` and `manager_user`, nobody else.
Whether RisingWave can grant a user query access while hiding source definitions I do not
know and will not guess; that is a concrete question for the RisingWave engagement Steve is
arranging, worth asking alongside the ALTER question.

---

## 5. How the apply-time path works, concretely

```
AWS Secrets Manager     op-usxpress-qa/risingwave/kafka   (account 527101283767)
        │               each cluster's IRSA role reads only its OWN account
        ▼
ExternalSecret          deploy/overlays/qa/externalsecret.yaml
        │                 → k8s Secret  etl-pipeline-credentials
ConfigMap               deploy/overlays/qa/endpoints.yaml
        │                 → k8s ConfigMap  etl-pipeline-endpoints
        ▼
the Job                 envFrom: both  →  ~28 env vars
        ▼
build/apply.sh          render(): %KAFKA_TOPIC_BRAND% → the env var's value
        │               REFUSES the file if any placeholder is unresolved, naming which
        ▼
that cluster's RisingWave
```

The split between the two sources:

| ConfigMap (`endpoints.yaml`) | Secret (Secrets Manager via ESO) |
|---|---|
| `KAFKA_TOPIC_BRAND` / `_DRIVER` / `_EMPLOYEE` / `_ACTIVE_RESOURCE` | `KAFKA_SASL_USERNAME` / `_PASSWORD` |
| `KAFKA_BOOTSTRAP_SERVER`, `KAFKA_SCHEMA_REGISTRY_SERVER` | `KAFKA_SCHEMA_REGISTRY_USERNAME` / `_PASSWORD` |
| `KAFKA_STARTUP_MODE`, `GROUP_ID_PREFIX` | `MONGODB_USERNAME` / `_PASSWORD` |
| `MONGODB_HOST`, `_PORT`, `_DATABASE_*`, `_COLLECTION_*` | `POSTGRES_ENTITY_USER` / `_PASSWORD` |
| `POSTGRES_SERVER`, `_PORT`, `_DB`, `_CDC_*` | |

Rule of thumb: if leaking it is embarrassing it is a secret; if it is an address it is config.
**Object names are identical in every environment** — `brand_source_kafka` exists in dev, QA
and prod. There is no collision because each cluster runs its own RisingWave. The isolation is
the AWS account boundary, not the SQL.

`apply.sh` also records a sha256 of each applied file in `pipeline_applied`, per cluster:
unchanged → skip, new → apply, **changed → refuse**. That refusal exists because every file in
the repo is drop-and-recreate (53 DROPs, 0 ALTERs across Tim's 44 files) and a silent re-run
would drop live objects and replay the whole Kafka topic.

---

## 6. The three fixes, as code

All three are written and tested. None of them depends on which design in section 3 we pick.

### 6.1 The guardrail — wrong in both directions

`pipeline.yaml` blocks this today:

```
DROP\s+(TABLE|DATABASE|SCHEMA|VIEW|MATERIALIZED\s+VIEW|SEQUENCE|INDEX|TYPE|FUNCTION|PROCEDURE)
```

No `IF EXISTS` exemption, and `SOURCE`, `SINK`, `SECRET`, `CONNECTION`, `USER`, `ROLE` are
missing. It blocks the safe form and lets the destructive one through.

```diff
-            if grep -qiP \
-              'DROP\s+(TABLE|DATABASE|SCHEMA|VIEW|MATERIALIZED\s+VIEW|SEQUENCE|INDEX|TYPE|FUNCTION|PROCEDURE)' \
-              "$file"; then
+            # ^\s*        a DROP that STARTS a statement, so "GRANT DROP SECRET" is not a drop
+            # …|SOURCE|SINK|SECRET|CONNECTION|USER|ROLE   the objects that were missing
+            # (?!IF\s+EXISTS)  a guarded drop is the safe, re-runnable form -- do not block it
+            if grep -qiP \
+              '^\s*DROP\s+(TABLE|DATABASE|SCHEMA|VIEW|MATERIALIZED\s+VIEW|SEQUENCE|INDEX|TYPE|FUNCTION|PROCEDURE|SOURCE|SINK|SECRET|CONNECTION|USER|ROLE)\s+(?!IF\s+EXISTS)' \
               "$file"; then
```

Same change on the `grep -niP` immediately after, which prints the offending lines.

**Four-case test — a gate has to be right in both directions, not just stricter:**

| statement | old | new | wanted | why |
|---|---|---|---|---|
| `DROP MATERIALIZED VIEW mv_brand;` | BLOCK | BLOCK | BLOCK | unguarded drop |
| `DROP SOURCE kafka_brand CASCADE;` | **ALLOW** | BLOCK | BLOCK | destructive; old rule missed it |
| `DROP MATERIALIZED VIEW IF EXISTS brand_mv_raw cascade;` | **BLOCK** | ALLOW | ALLOW | guarded, and mandatory in Tim's style |
| `GRANT DROP SECRET ON DATABASE dev TO manager_user;` | ALLOW | ALLOW | ALLOW | a GRANT, not a DROP — what `^\s*` protects |

**Against Tim's real tree: old blocks 19 of 44 files, new blocks 0 of 44** — while newly
catching the unguarded `DROP SOURCE` that used to pass.

### 6.2 `.sql` files land in the wrong database

`apply.sh` already routes by extension, so `.sql` "works":

```bash
case "$f" in
  *.rw)  ... | rw -q -f - ;;    # -> RisingWave, port 4567
  *.sql) pg -q -f "$f" ;;       # -> Postgres,   port 5432
esac
```

The problem is *where*. `pg()` points at `PG_HOST`/`PG_DB` = `pg-postgresql` / `risingwave` —
**RisingWave's own meta store**, which is also where `pipeline_applied` lives. Tim's `.sql`
files create `public.activeresource` and `employee.*`. Those must not go there.

One connection is doing two unrelated jobs. Split it:

```diff
 PG_HOST="${PG_HOST:?PG_HOST not set}"
 PG_PORT="${PG_PORT:-5432}"
 PG_DB="${PG_DB:-postgres}"
 PG_USER="${PG_USER:-postgres}"
+
+# The APPLICATION database -- where .sql files build tables. Deliberately NOT the meta
+# store. Tim's placeholders already name it: POSTGRES_SERVER / _ENTITY_DB / _ENTITY_USER.
+APP_HOST="${POSTGRES_SERVER:-}"
+APP_PORT="${POSTGRES_PORT:-5432}"
+APP_DB="${POSTGRES_ENTITY_DB:-}"
+APP_USER="${POSTGRES_ENTITY_USER:-}"

 pg()  { PGPASSWORD="${PG_PASSWORD}" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 "$@"; }
+app() { PGPASSWORD="${POSTGRES_ENTITY_PASSWORD}" psql -h "$APP_HOST" -p "$APP_PORT" -U "$APP_USER" -d "$APP_DB" -v ON_ERROR_STOP=1 "$@"; }
```

and route `.sql` to it, refusing rather than guessing:

```diff
   case "$f" in
     *.rw)
       sed -e '/^statement/d' -e '/^query/d' -e '/^----$/,+0d' "$f" | rw -q -f - ;;
-    *.sql) pg -q -f "$f" ;;
+    *.sql)
+      if [ -z "$APP_HOST" ] || [ -z "$APP_DB" ] || [ -z "$APP_USER" ]; then
+        echo "  REFUSED  ${rel}"
+        echo "           a .sql file needs an application database, but POSTGRES_SERVER /"
+        echo "           POSTGRES_ENTITY_DB / POSTGRES_ENTITY_USER are not all set."
+        echo "           Refusing to run it against ${PG_HOST}/${PG_DB} -- that is"
+        echo "           RisingWave's meta store, not an application database."
+        exit 1
+      fi
+      if [ "${APP_HOST}:${APP_DB}" = "${PG_HOST}:${PG_DB}" ]; then
+        echo "  REFUSED  ${rel}"
+        echo "           the application database resolves to the meta store"
+        echo "           (${PG_HOST}/${PG_DB}). Point POSTGRES_ENTITY_DB somewhere else."
+        exit 1
+      fi
+      app -q -f "$f" ;;
   esac
```

Two properties worth noting. The variables are checked **only when a `.sql` file actually
appears**, so a Brand-only run needs none of them. And the second check makes it impossible to
write application tables into the meta store even if someone sets the variables to the same
place — it fails loudly instead of succeeding quietly.

The overlays then gain `POSTGRES_SERVER`, `POSTGRES_PORT`, `POSTGRES_ENTITY_DB` in the
ConfigMap and `POSTGRES_ENTITY_USER` / `_PASSWORD` in the ExternalSecret.

### 6.3 The credential in `SHOW CREATE SOURCE`

This is the security cost of step 1 in section 4, and this is exactly what step 2 removes.
The change, when the licence lands, is mechanical:

**`pipelines/000-shared/000-secrets.rw`** — add the secrets under Tim's names, fed by the same
renderer that is already supplying them:

```sql
DROP SECRET IF EXISTS kafka_sasl_password;
CREATE SECRET kafka_sasl_password WITH ( backend = 'meta' ) AS '%KAFKA_SASL_PASSWORD%';
DROP SECRET IF EXISTS kafka_schema_registry_password;
CREATE SECRET kafka_schema_registry_password WITH ( backend = 'meta' ) AS '%KAFKA_SCHEMA_REGISTRY_PASSWORD%';
```

**Tim's source files** — one substitution per credential:

```diff
-  properties.sasl.password  = '%KAFKA_SASL_PASSWORD%',
+  properties.sasl.password  = secret kafka_sasl_password,
-  schema.registry.password  = '%KAFKA_SCHEMA_REGISTRY_PASSWORD%'
+  schema.registry.password  = secret kafka_schema_registry_password
```

Keeping **Tim's names** (`kafka_sasl_password`, not `kafka_api_secret`) means the diff is a
`sed`, not a rewrite, and his files stay readable to him.

**Nothing in `build/`, `deploy/` or the workflows changes.** The renderer keeps feeding values
in; the SQL stops consuming them directly and starts consuming secret objects. That is the
whole of step 2 — which is why it is a follow-up and not a blocker.

**Until then**, the exposure is bounded by who can run `SHOW CREATE SOURCE` on that cluster:
today `root` and `manager_user`, nobody else. Whether RisingWave can grant query access while
hiding source definitions I do not know and will not guess — a concrete question for the
RisingWave engagement, alongside the ALTER one.

---

## 7. What I need from you

1. **Read section 3 and 4 and tell me if you disagree.** You said you'd make the call and I meant it.
2. **The account ARN fix** — `secret.yaml:90` hardcodes account `700736442855` (dev) for every
   environment; the dropdown only changes the role *name*. `pipeline.yaml:178` hardcodes both
   account and `-dev-`. `user-access-deploy.yaml:95` uses one repo-level `AWS_ACCOUNT_ID`.
3. **The guardrail fix** in section 6.
4. If we go apply-time, I'll add the **16 variables** Tim's SQL needs that our overlays don't
   define yet — that's mine, not yours.

## 8. Explicitly not decided

Everything in section 6 is decided and written. These are not:

* **SQLMesh** — discovery ticket. It would replace `apply.sh` (which SQL to run), not the
  image or Argo CD (what reaches which cluster). Different halves — worth saying early or it
  becomes "SQLMesh vs our CI/CD". I said in standup that it is not RisingWave-owned and may
  not be supported; **that is my assumption, not something I verified.** Your PoC settles it.
  It is Apache-2.0 from Tobiko Data; the paid product is Tobiko Cloud, a separate thing.

* **When step 2 happens** (section 6.3) — it needs the licence, and it needs Tim to accept a
  `sed` across his source files. Worth agreeing with him rather than doing to him.

* **`400-Driver/rw.sql`** — misnamed: a `.sql` extension on a file called "rw". Empty today,
  so harmless, but if it ever gets RisingWave SQL it goes to Postgres and fails. Rename during
  Tim's merge.

* **`000-Demos/`** on `f/driver` — 153 lines of RAG demo SQL that sorts *before* `000-shared/`,
  so it would run first in every environment. Needs `EXCLUDE_RE: "/(000-Demos|Template|shared/scripts)/"`.
  Not optional, just not yet written.

## 9. Suggested order: Brand only, first

`pipelines/100-Brand/` is four files and **zero `.sql`**:

```
100-sources.rw   200-ingest.rw   300-transform-flat.rw   400-sink.rw
```

So the first cutover needs no second Postgres connection, no CDC, and no licence. It is the
smallest thing that exercises the whole path with real DDL rather than `SELECT 1`.

Then add ActiveResource, Employee and Driver — doing the connection split as part of that.
Four pipelines at once and we will not be able to tell which one broke.

One more thing worth knowing about the merge: `rel` in `apply.sh` is the file's path, and
Tim's rename `Brand/` -> `100-Brand/` changes every path, so every file looks new to
`pipeline_applied`. On QA that is exactly what we want (we emptied the table on 27 Aug). On a
cluster with history it would re-apply everything. Nothing has history except dev, and dev
does not use this path — so the rename is free right now, and would not be later.

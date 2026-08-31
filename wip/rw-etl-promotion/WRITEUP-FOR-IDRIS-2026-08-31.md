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

## 3. The one real decision

**Where does the credential get resolved?**

| | Yours — inside RisingWave | Mine — at apply time |
|---|---|---|
| Mechanism | `CREATE SECRET kafka_api_key …` then `properties.sasl.password = secret kafka_api_key` | `%KAFKA_SASL_PASSWORD%` in the SQL, replaced from an env var before it is sent |
| Values come from | Secrets Manager → GitHub Action → `CREATE SECRET` | Secrets Manager → External Secrets → k8s Secret → `envFrom` |
| Non-secret values (topics, hosts) | **no home** — the workflow only does secrets | ConfigMap `etl-pipeline-endpoints` |
| Premium licence | **required** — Secrets Management is gated | not required |
| Credential visible in `SHOW CREATE SOURCE` | **no** | **yes** |
| CI needs prod credentials | **yes** | no — the Action only pushes to ECR |

Your version is genuinely better on the security row. INFRA-1637 removed the plaintext
Confluent credentials from `pipelines/Brand/100-sources.rw` on 18 Aug and that was the right
fix. I want to be clear I am not arguing your design is careless — it is not.

---

## 4. Why I am recommending apply-time resolution anyway

Three reasons, in order of weight.

**(a) Tim's tree does not use `secret <name>` at all.**
`f/driver` — the branch actually running on op-dev, which Tim confirmed is current and is
merging to master — writes credentials inline:

```sql
properties.sasl.password  = '%KAFKA_SASL_PASSWORD%',
schema.registry.password  = '%KAFKA_SCHEMA_REGISTRY_PASSWORD%'
```

Across all 44 of his SQL files there are **zero** `secret <name>` references. When his
`pipelines/` lands, the 15 RisingWave secrets become orphans — created, licence-gated, and
referenced by nothing. Keeping the `CREATE SECRET` design means rewriting all 44 of his files.

**(b) It takes the premium licence off the critical path.**
You have been blocked waiting for the licence key because `CREATE SECRET` needs it. Tim's SQL
does not call it. We can test end to end this week without the key.

**(c) Non-secret values need somewhere to live.**
`secret.yaml` handles credentials well. It has no home for a Kafka **topic name**, a MongoDB
host, or a Postgres database name — and those differ per environment too. Right now
`deploy/overlays/qa/endpoints.yaml` has no Kafka keys at all, because QA has only ever
deployed the `smoke/` payload. That gap has to be filled either way.

**The cost of my recommendation, stated plainly:** the credential ends up inside the source
definition, so anyone with `SHOW CREATE SOURCE` can read it. That is exactly how I saw live
Confluent credentials last week. Mitigation is RisingWave user permissions, and moving to
`CREATE SECRET` as a follow-up once the licence lands — not a reason to block the cutover.

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

## 6. A bug in the guardrail, independent of which design wins

`pipeline.yaml` blocks this pattern:

```
DROP\s+(TABLE|DATABASE|SCHEMA|VIEW|MATERIALIZED\s+VIEW|SEQUENCE|INDEX|TYPE|FUNCTION|PROCEDURE)
```

No `IF EXISTS` exemption, and `SOURCE`, `SINK`, `SECRET`, `USER`, `ROLE` are not in the list.
Tested against Tim's files:

```
BLOCKED  DROP MATERIALIZED VIEW IF EXISTS brand_mv_raw cascade;   ← safe and mandatory
ALLOWED  DROP SOURCE IF EXISTS brand_source_kafka CASCADE;        ← genuinely destructive
ALLOWED  DROP SECRET IF EXISTS kafka_api_key;                     ← genuinely destructive
```

**19 of Tim's 44 files are blocked** by it today, and the destructive statements pass. The fix
is to exempt `IF EXISTS` and add the missing object types. Worth doing whichever design we pick.

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

* **SQLMesh** — discovery ticket. It would replace `apply.sh`, not the image or Argo CD.
  Different halves of the problem. I said in standup that it isn't RisingWave-owned and may
  not be supported; that is my assumption, not something I verified. Your PoC settles it.
* **`CREATE SECRET` as a follow-up** once the licence lands — I think it should happen, just
  not as a blocker.
* **A second Postgres connection** for `.sql` files. `apply.sh` has one `pg()` doing two jobs:
  the `pipeline_applied` bookkeeping and application tables. Tim's `.sql` files create
  `public.activeresource` and `employee.*`, which must not land in RisingWave's meta store.
  Only affects ActiveResource and Employee — **Brand has no `.sql` at all**, so it does not
  block the first cutover.

## 9. Suggested order

Brand only, first. Four `.rw` files, no `.sql`, no CDC, no second Postgres. Prove the path
with real DDL, then add the other three pipelines. Four at once and we cannot tell which broke.

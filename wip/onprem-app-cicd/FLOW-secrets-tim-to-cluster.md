# How Tim's work reaches a cluster, and where secrets enter — 2026-10-08

Two things travel and one thing does not. **His SQL travels** through Git and CI into an image.
**Config travels** through Git as a ConfigMap. **Secrets never travel** — they are written once
per AWS account and are pulled in at the far end.

That is the whole design, and it is why "how do I push my `.env`" has no single answer.

---

## The picture

```
  TIM'S LAPTOP                         SHARED REPO                       ONE CLUSTER
  (docker-compose)                 variant-inc/risingwave-pipeline       (op-dev / op-qa / op-prod)
  ──────────────────               ─────────────────────────────         ──────────────────────────

  pipelines/Brand/*.rw   ──PR──►   pipelines/Brand/*.rw
  pipelines/Employee/*            pipelines/Employee/*
        (his SQL)                         │
                                          │  CI on push to master
                                          ▼
                                 ┌──────────────────────┐
                                 │ 1 validate           │  SQL guardrails: blocks
                                 │   (SQL guardrails)   │  unguarded DROP / injection
                                 └──────────┬───────────┘
                                            ▼
                                 ┌──────────────────────┐
                                 │ 2 approve            │  GitHub Environment
                                 │   (human gate)       │  "pipeline-approval"
                                 └──────────┬───────────┘
                                            ▼
                                 ┌──────────────────────┐
                                 │ 3 build → ECR        │  applier image, pinned
                                 │   (digest)           │  by DIGEST, not tag
                                 └──────────┬───────────┘
                                            ▼
                                 ┌──────────────────────┐
                                 │ 4 promotion PR       │  writes the new digest into
                                 │   per environment    │  deploy/overlays/<env>/
                                 └──────────┬───────────┘
                                            │  merge = CD starts
  ──────────────────────────────────────────┼──────────────────────────────────────────────
                                            ▼
                                                                   ┌─────────────────────┐
  his .env  ──✗ never leaves the laptop                            │ Argo CD             │
                                                                   │ app: risingwave-etl │
                                                                   │ watches             │
                                                                   │ deploy/overlays/dev │
                                                                   └──────────┬──────────┘
                                                                              ▼
                                                              namespace  app-risingwave
                                                              ┌───────────────────────────┐
                                                              │ ETL Job (sync hook)       │
                                                              │  runs build/apply.sh      │
                                                              └───────────┬───────────────┘
                                                                          │ psql 4567
                                                                          ▼
                                                              namespace  risingwave
                                                              ┌───────────────────────────┐
                                                              │ RisingWave               │
                                                              │  frontend / compute / meta│
                                                              └───────────────────────────┘
```

---

## Where secrets enter — there are TWO paths, and Tim only cares about the second

### Path 1 — the Job's own login (so `apply.sh` can connect)

```
  AWS Secrets Manager                 cluster                          the Job
  op-usxpress-<env>/risingwave/
     root      ─┐
     postgres  ─┤──► ExternalSecret ──► k8s Secret ──► env vars ──► RW_PASSWORD
                │    (deploy/overlays/   etl-pipeline-              PG_PASSWORD
                │     <env>/external-    credentials                PG_USER
                │     secret.yaml)
```

Resolved **at pod creation**. A value change does not reach a running pod; the pod must be
deleted. Nothing in Git holds the value — only the *key name*.

### Path 2 — credentials used INSIDE his SQL (Tim's actual question)

He wants to write a Kafka password into `CREATE SOURCE`. He must not, and he does not have to.

```
  AWS Secrets Manager                 GitHub Actions                   RisingWave
  op-usxpress-<env>/
     risingwave/kafka   ──────►  .github/workflows/secret.yaml  ──►  CREATE SECRET
     (9 properties)              workflow_dispatch:                   kafka_api_key
                                   environment: dev|qa|prod            kafka_api_secret
                                   connector:   kafka|mongodb|both     ... 12 objects
                                 assumes OIDC role
                                 renders %TOKEN% into                encrypted with
                                 pipelines/000-shared/                secret_store_private_key
                                   000-secrets-kafka.rw               in the meta store
                                 runs it via psql                             │
                                                                              ▼
                                                            his SQL references it by NAME:
                                                            properties.sasl.password
                                                              = secret kafka_api_secret
```

**Run once per environment.** It is a dropdown, not a promotion — nothing carries it from dev
to QA. The file is idempotent (`DROP SECRET IF EXISTS` before each `CREATE`), so re-running is
safe.

### And the third thing, which is not a secret at all

```
  deploy/overlays/<env>/endpoints.yaml   ──►  ConfigMap  ──►  env vars in the Job
     RW_HOST, RW_PORT, RW_DB, PG_HOST, KAFKA_TOPIC_BRAND,
     KAFKA_STARTUP_MODE, GROUP_ID_PREFIX, PIPELINE_DIR, EXCLUDE_RE
```

Topic names, hosts and schema names live here, in Git, per environment. This is where most of
Tim's `.env` lands — 40 of his 75 keys.

---

## What we added to the shared repo to make this work

| file | what it does | secrets role |
|---|---|---|
| `build/apply.sh` | renders `%TOKEN%`s from env, selects files, runs them in filename order | consumes Path 1 env vars |
| `deploy/base/job.yaml` | the applier Job | mounts the ConfigMap + Secret |
| `deploy/overlays/<env>/endpoints.yaml` | per-environment ConfigMap | the non-secret half |
| `deploy/overlays/<env>/externalsecret.yaml` | names which Secrets Manager keys to pull | **Path 1** |
| `deploy/overlays/<env>/kustomization.yaml` | pins the image by digest | — |
| `pipelines/000-shared/000-secrets-kafka.rw` | the twelve `CREATE SECRET` statements | **Path 2** |
| `pipelines/000-shared/001-secrets-mongodb.rw` | same, for Mongo | **Path 2** |
| `.github/workflows/secret.yaml` | syncs Secrets Manager → `CREATE SECRET`, per environment | **Path 2** |

Tim adds **only** `pipelines/<Entity>/*.rw` and `*.sql`. Everything above is ours.

---

## Per environment, today

| | dev | QA | prod |
|---|---|---|---|
| Argo CD app for the ETL | ❌ being wired now | ✅ | ✅ |
| Path 1 — ExternalSecret | n/a yet | ✅ (3 of 5 keys; `entity-postgres` never created) | overlay has no `image-digest.yaml` |
| Path 2 — the 12 secrets | ❌ never run | ✅ created **by hand**, prefix needs refresh | ❌ |
| `secret.yaml` workflow | never completed a run in **any** environment | | |
| GitHub environment secrets | 4 | was 0; needs `RISINGWAVE_HOST`, `RISINGWAVE_PORT` | the `prod` environment does not exist |

---

## The four things that will bite

1. **`secret.yaml` has never completed a run anywhere.** The mechanism is proven — I ran the
   same DDL by hand on QA and listed 12 rows from `rw_catalog.rw_secrets`. The automation is
   not. Fix is three one-liners (the OIDC role name, the role's resource ARN, two GitHub
   environment variables).
2. **Property casing differs per account** — dev `KAFKA__…`, QA `kafka__…`. Code reading one
   casing gets nothing from the other, silently.
3. **ESO writes a partial Secret.** One missing key still yields a Secret that looks full; the
   pod dies at container creation with `RESTARTS 0`. Count keys, never read the condition.
4. **A Secrets Manager write has no gate.** The only reviewed step in the whole secret flow is
   the PR that adds the *reference*. Values, and the `secret.yaml` dropdown, have no gate at
   all — dev → QA → prod is discipline, not mechanism.

## Proven

- Two distinct secret paths, with different mechanisms and different failure modes; Tim's
  question is entirely about Path 2.
- 40 of Tim's 75 keys are ConfigMap values, not secrets.

## Tested and killed

- "Tim's `.env` goes somewhere." It does not travel at all — it is replaced by a ConfigMap, an
  ExternalSecret and twelve `CREATE SECRET` objects.

## Traps

- CI is green and the Job still applies nothing: `PIPELINE_DIR` and `EXCLUDE_RE` decide which
  files run, and an excluded file looks identical to a passing one from the sync status.
- The `wip/onprem-app-cicd/rw-pipeline/` tree in this repo is a **snapshot**. Read the branch
  before acting on any path above.

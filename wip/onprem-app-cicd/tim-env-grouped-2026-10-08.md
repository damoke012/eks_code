# Tim's three grouped `.env` files, sorted — 2026-10-08

Tim split his `.env` into `_docker.env`, `_Platform.env` and `_dev.env`. Two of the three
groupings are right. This note sorts them into cluster destinations, now that the target is
the **Helm** `usxpress-app` chart rather than kustomize overlays.

## ⚠️ FIRST — live credentials arrived in plaintext

`_Platform.env.txt` carries **real values** for four keys:

    KAFKA_SASL_USERNAME          KAFKA_SASL_PASSWORD
    KAFKA_SCHEMA_REGISTRY_USERNAME   KAFKA_SCHEMA_REGISTRY_PASSWORD

These are not Tim's credentials. They are copies of the per-account masters
`dx__risingwave-kafka-creds` and `dx--ccloud-schema-registry-master`, which every consumer in
the account copies from — dev's `op-usxpress-dev/risingwave/kafka` holds values byte-identical
to the master. The schema-registry pair is shared between dev and QA.

They are now in an email thread and in a file on at least two laptops. **Rotate in
`variant-inc/iaac-confluent-cloud`, then re-sync every copy** — the RisingWave secrets, and
any other consumer of those masters. Until then treat them as disclosed.

The Mongo, Postgres, CDC and entity passwords in the same file are docker-compose local values
(`postgres/postgres`, `root/abcd`, `password2`, `password3`) and carry no cluster risk.

**The process lesson:** the ask was for **key names**, and values came back. The ask has to say
why, not just what — "key names only, a value in an email is in a system we don't control".

---

## Where secrets live with Helm in the mix

Helm changes **where the manifest comes from**, not where the secret lives. There are still
exactly **three** destinations, and the chart touches only two of them.

| type | where the VALUE lives | how it reaches the workload | who owns it |
|---|---|---|---|
| **1. Pod env secret** | AWS Secrets Manager | Helm values name the KEY → chart renders an ExternalSecret → ESO writes a k8s Secret → env var at **pod creation** | platform |
| **2. RisingWave SECRET object** | AWS Secrets Manager | `secret.yaml` workflow → `CREATE SECRET … backend='meta'` → referenced in SQL as `secret <name>` | platform, **untouched by Helm** |
| **3. Not a secret** | the Helm values file, in Git | chart renders a ConfigMap → env var | split: platform or developer |

Plus a fourth that is not the app's at all: **cluster-level** secrets — `console_license_key`,
`secret_store_private_key`, `dex_entra_client_secret` — owned by the RisingWave platform
chart, never by the pipeline.

**The rule that survives the Helm move:** a Helm values file may contain a secret's **key
name**. It may never contain a secret's **value**. `values-<env>.yaml` is in Git exactly like
the overlay was.

---

## `_docker.env` — local only, with one correction

Correct to exclude from the cluster: `RW_IN_CONTAINER`, and the nine image version pins. In
the cluster, versions are pinned by **digest**, by the chart and the promotion workflow.

⚠️ **Four keys in this file are not docker-only.** `RUST_BACKTRACE`, `RUST_LOG`,
`ENABLE_TELEMETRY` and `RW_TELEMETRY_TYPE` are **RisingWave runtime settings**. In the cluster
they belong to the RisingWave CR in `iaac-risingwave-onprem`, which we already own — so they
leave Tim's file but do not disappear. `RUST_LOG=debug` in particular is a deliberate choice
per environment, not a local convenience.

## `_Platform.env` — right owner, wrong axis

This is the file that proves the point from [[secret-and-owner-are-two-axes]]: it is a correct
*ownership* group and it mixes secret with non-secret. It splits:

**Type 3 — Helm values, non-secret (platform-owned):**

    POSTGRES_SERVER  POSTGRES_PORT  POSTGRES_HOST_NAME  POSTGRES_INTERNAL_PORT  POSTGRES_DB
    POSTGRES_CDC_PUBLICATION  POSTGRES_CDC_SLOT  POSTGRES_CDC_DECODING_PLUGIN  DB_ANON_ROLE
    RW_HOST  RW_HOST_NAME  RW_PORT  RW_DB  RW_USER
    MONGODB_HOST  MONGODB_PORT  MONGODB_INITDB_DATABASE
    KAFKA_BOOTSTRAP_SERVER  KAFKA_SECURITY_PROTOCOL  KAFKA_SASL_MECHANISM
    KAFKA_STARTUP_MODE  scan_startup_mode  KAFKA_SCHEMA_REGISTRY_SERVER
    KAFKA_SCHEMA_REGISTRY_MESSAGE  GROUP_ID_PREFIX  POSTGRES_ENTITY_DB

**Type 1 — pod env secret (ExternalSecret):**

    POSTGRES_USER  POSTGRES_PASSWORD  POSTGRES_CDC_USER  POSTGRES_CDC_PASSWORD
    POSTGRES_ENTITY_USER  POSTGRES_ENTITY_PASSWORD  RW_PASSWORD

**Type 2 — RisingWave `CREATE SECRET`, already exist, nothing for Tim to do:**

    KAFKA_SASL_USERNAME  KAFKA_SASL_PASSWORD
    KAFKA_SCHEMA_REGISTRY_USERNAME  KAFKA_SCHEMA_REGISTRY_PASSWORD
    MONGODB_USERNAME  MONGODB_PASSWORD

`POSTGRES_ENTITY_URL` is **empty**, so there is no connection string to split after all — the
concern raised earlier does not apply to this file.

## `_dev.env` — correct as grouped

Every key here is non-secret and developer-owned: per-entity topic, Postgres schema, Mongo
database and collection. All go in the Helm values file, in the section Tim raises PRs against.

---

## Six defects visible in the values

1. **`KAFKA_SCHEMA_REGISTRY_MESSAGE=abc123`** — a placeholder that satisfies a non-empty
   check and then fails inside RisingWave at decode time, the same class as the `unknown` that
   blocked PR #29. The real value is the Avro subject's namespace + record, read from the
   registry: QA's Brand is `USXpress.Standard.Types.Brand.V1.company_master`.
2. ~~**`GROUP_ID_PREFIX=dx__dev_risingwave_risingwave_dev`** — `risingwave` appears twice.~~
   ⛔ **WRONG, corrected the same evening.** The doubled form is the **house convention**, not
   a typo: our own `deploy/overlays/qa/endpoints.yaml` sets
   `KAFKA_GROUP_ID_PREFIX: dx__qa_risingwave_risingwave_qa` and its comment names dev's as
   `dx__dev_risingwave_risingwave_dev` — Tim's value exactly. I compared it against
   `kafka__group_id_prefix = dx__qa_risingwave` in Secrets Manager, which is a **different
   key in a different system**, and called a convention a defect.
   What *is* true and worth keeping: the two environments must never share a prefix, because
   one consumer group across both splits the partitions between them — QA would take messages
   dev never sees, and dev would go silently, partially blind.
3. **Three of four entity topics are `_json`, not `_avro`.** Only Brand
   (`dev_brand_management_cdc_brand_avro`) is Avro. Employee, Driver and ActiveResource are
   JSON, so they use a different `FORMAT … ENCODE` and **do not touch the schema registry at
   all**. The registry credential is a Brand-only dependency.
4. **`KAFKA_TOPIC_EMPLOYEE=dev_timmyp_cdc_employee_json`** is a personal topic. It will not
   exist in QA or prod; that entity needs a real per-environment topic before promotion.
5. **ActiveResource is half-filled** — it has a topic but empty schema, database and
   collection, so it will render empty values that pass any non-empty check applied per file
   rather than per key.
6. **`### Entity: Truck ###` still has no keys**, so Truck reads as configured and is not.

Local-vs-cluster values that must not be copied across: `RW_PORT` is `4566` locally and
**4567** in cluster; `POSTGRES_PORT` `8432` vs **5432**; `POSTGRES_DB` is `metadata` locally
and **`risingwave`** in cluster; `RW_HOST`/`POSTGRES_SERVER` are `localhost`. `RW_DB=dev` is
correct and stays `dev` in **every** environment.

## Proven

- Tim's own grouping is two-thirds correct; the platform group is the one that splits, exactly
  as the two-axis model predicted.
- Helm does not change the secret flow. Type 2 is entirely outside the chart.
- Only Brand depends on the schema registry.

## Tested and killed

- "`POSTGRES_ENTITY_URL` is a connection string we must split" — it is empty in his file.

## Traps

- A values file is Git. Helm makes it look like configuration rather than source, and a
  secret pasted into `values-prod.yaml` is as published as one pasted into an overlay.
- `abc123` and `dx__dev_risingwave_risingwave_dev` both pass every non-empty check in the
  path and fail far downstream, in different subsystems.

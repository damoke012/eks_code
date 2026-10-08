# Tim's `.env` template, sorted — 2026-10-08

Source: the `.env.example` from Tim's RisingWave repo, pasted as **key names only, no values**.
**75 keys.** Every one is assigned below; the buckets are exhaustive and disjoint.

## Headline

| destination | count |
|---|---|
| ConfigMap — `risingwave-pipeline/deploy/overlays/<env>/endpoints.yaml` | 40 |
| **New** secrets → AWS Secrets Manager + ExternalSecret | 9 (+1 to split) |
| Already exist, do **not** recreate — `op-usxpress-<env>/risingwave/kafka` | 5 |
| Not the pipeline's — RisingWave cluster CR in `iaac-risingwave-onprem` | 3 |
| Drop — docker-compose image pins with no k8s equivalent | 9 |
| Placeholder rows (`template` entity) | 4 |
| Need a ruling from Tim | 4 |

So **ten** of seventy-five keys are new secret material. The Kafka credential question that
prompted this is already solved.

## 1. ConfigMap — `deploy/overlays/<env>/endpoints.yaml` (40)

    POSTGRES_SERVER  POSTGRES_PORT  POSTGRES_DB
    POSTGRES_CDC_PUBLICATION  POSTGRES_CDC_SLOT  POSTGRES_CDC_DECODING_PLUGIN
    RW_HOST  RW_PORT  RW_DB  RW_USER
    MONGODB_HOST  MONGODB_PORT  MONGODB_INITDB_DATABASE
    KAFKA_BOOTSTRAP_SERVER  KAFKA_SECURITY_PROTOCOL  KAFKA_SASL_MECHANISM
    KAFKA_STARTUP_MODE  KAFKA_SCHEMA_REGISTRY_MESSAGE  GROUP_ID_PREFIX
    RUST_BACKTRACE  ENABLE_TELEMETRY  RW_TELEMETRY_TYPE  RUST_LOG
    POSTGRES_ENTITY_DB
    KAFKA_TOPIC_{BRAND,EMPLOYEE,DRIVER,ACTIVE_RESOURCE}
    POSTGRES_ENTITY_SCHEMA_{BRAND,EMPLOYEE,DRIVER,ACTIVE_RESOURCE}
    MONGODB_DATABASE_{BRAND,EMPLOYEE,DRIVER,ACTIVE_RESOURCE}
    MONGODB_COLLECTION_{BRAND,EMPLOYEE,DRIVER,ACTIVE_RESOURCE}

Four of these are **ours to set, not his** — his values are EKS/local values:

| key | on-prem value | why |
|---|---|---|
| `RW_DB` | `dev`, in **every** environment | the database really is named `dev`; verified by SQL on QA |
| `RW_HOST` / `RW_PORT` | `risingwave-frontend.risingwave.svc.cluster.local` / `4567` | in-cluster service |
| `POSTGRES_SERVER` | `pg-postgresql.risingwave.svc.cluster.local` | an **empty** value here wedged QA for 9 days |
| `GROUP_ID_PREFIX` | ours | his comment points at the EKS ConfigMap `risingwave-kafka-group` |

## 2. New secrets → Secrets Manager + ExternalSecret (9, +1 split)

    POSTGRES_USER  POSTGRES_PASSWORD
    POSTGRES_CDC_USER  POSTGRES_CDC_PASSWORD
    POSTGRES_ENTITY_USER  POSTGRES_ENTITY_PASSWORD
    MONGODB_USERNAME  MONGODB_PASSWORD
    RW_PASSWORD

`POSTGRES_ENTITY_URL` is a connection string carrying the password. **Split it** — host, port
and db to the ConfigMap, password to Secrets Manager — or the secret leaks into Git by
riding inside a "config" value.

## 3. Already exist — do NOT recreate (5)

    KAFKA_SASL_USERNAME        -> op-usxpress-<env>/risingwave/kafka : api_key
    KAFKA_SASL_PASSWORD        ->                                     api_secret
    KAFKA_SCHEMA_REGISTRY_SERVER   ->                                 schema_registry_endpoint
    KAFKA_SCHEMA_REGISTRY_USERNAME ->                                 schema_registry_api_key
    KAFKA_SCHEMA_REGISTRY_PASSWORD ->                                 schema_registry_api_secret

These never become pod env vars. `secret.yaml` reads them and issues `CREATE SECRET` inside
RisingWave — twelve objects, nine from AWS keys plus three literals — and the SQL references
`secret kafka_sasl_password`. The registry three are a **copy** of the per-account
`dx--ccloud-schema-registry-master` (dev's are byte-identical, compared by sha256), which is
the house convention, managed in `variant-inc/iaac-confluent-cloud`.

Tim's own comment already names `dx--ccloud-schema-registry-master`, so he knows this one.
His other comment, `dx__risingwave-kafka-creds`, is the **EKS** secret — on-prem has its own.

## 4. Not the pipeline's (3)

    RW_LICENSE_KEY  RW_META_SECRET_STORE_PRIVATE_KEY  RW_SECRET_STORE_PRIVATE_KEY_HEX

These configure the RisingWave **cluster**, not the ETL pod. They belong to the CR / Helm
values in `iaac-risingwave-onprem`. Putting them in the pipeline's ConfigMap would be a
second, divergent owner of the meta secret-store key — and if those two ever disagree,
RisingWave cannot read back the secrets it already stored.

## 5. Drop (9)

    GRAFANA_VERSION  GRAFANA_LOKI_VERSION  GRAFANA_ALLOY_VERSION  GRAFANA_TEMPO_VERSION
    PROMETHEUS_VERSION  ALPINE_VERSION  POSTGRES_VERSION  MINIO_VERSION  MONGODB_VERSION

docker-compose image pins. In the cluster, versions live in the chart and the kustomize
overlay, pinned by **digest**. MinIO has no on-prem counterpart at all — Hummock is S3.

## 6. Needs a ruling from Tim (4)

| key | question |
|---|---|
| `scan_startup_mode` | duplicates `KAFKA_STARTUP_MODE`, lowercase. Which one does the SQL read? |
| `RW_IN_CONTAINER` | always true in k8s — can we hardcode it, or does a script branch on it? |
| `RW_HOST_NAME` | how does it differ from `RW_HOST`? |
| `DB_ANON_ROLE` | PostgREST-shaped. What consumes it? |

## Defects in the template itself

1. **Two keys have a space before the `=`** — `RW_META_SECRET_STORE_PRIVATE_KEY =` and
   `RW_SECRET_STORE_PRIVATE_KEY_HEX =`. Most parsers then produce a key with a trailing
   space, which matches nothing. These are exactly the two keys whose silent absence means
   RisingWave cannot decrypt its own stored secrets.
2. **`### Entity: Truck ###` has no keys under it**, and Brand's four keys sit under the
   `### Entity: template ###` header. So Truck reads as configured and is not, and Brand
   reads as the template.
3. **Case matters and already bit us** — dev's AWS keys are `KAFKA__…`, QA's are `kafka__…`,
   a candidate cause of `secret.yaml`'s failed run on 2026-09-02. `scan_startup_mode` is the
   same hazard inside the `.env`.
4. **`KAFKA_SCHEMA_REGISTRY_MESSAGE` must never be `unknown`.** PR #29 set that literal; it
   satisfies `apply.sh`'s non-empty check and then fails inside RisingWave at decode time. A
   blank fails loudly, `unknown` fails quietly.

## Proven

- 75 keys, all assigned. Ten are new secret material; the five Kafka credentials already
  exist per environment and the registry three are a copy of an account-level secret.
- The Kafka path does not use pod env vars for credentials at all — `CREATE SECRET` inside
  RisingWave, referenced by name in the SQL.

## Tested and killed

- "All the `.env` keys become secrets." Nine of seventy-five, plus one to split.
- "The Kafka gap needs a Confluent admin" — killed 2026-09-11; the repo is
  `iaac-confluent-cloud` and the credential is copied, not minted.

## Traps

- A placeholder that satisfies a validator (`unknown`) beats the guard and fails downstream.
- An empty string reads as configured — QA's three registry fields were present and empty.
- A connection string smuggles a password into the config bucket.
- Env vars resolve at **pod creation**; rotating the Secrets Manager value changes nothing
  until the pod is recreated.
- ESO writes the keys it *could* resolve. One missing key still reports partly-green and the
  pod dies at container creation with `RESTARTS 0` — invisible to restart alerts.

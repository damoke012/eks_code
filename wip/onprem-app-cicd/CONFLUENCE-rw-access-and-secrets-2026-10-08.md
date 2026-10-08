# RisingWave Access and Secrets

**Last verified: 2026-10-08.** Every status in the inventory below carries the date it was
measured and how. Where a thing has not been checked, it says so rather than being omitted.

## Purpose

How credentials reach RisingWave on the on-prem clusters, who creates each one, and how to
tell whether a credential actually works — as opposed to reporting green.

There are **three** separate secret flows plus a set of hand-set values. They use different
mechanisms, have different owners, and fail in different ways. Treating them as one flow is
the most common source of error on this page's subject.

| flow | what it carries | mechanism | ends up as |
|---|---|---|---|
| **A — Platform** | cluster, console and Dex credentials | Terraform → Secrets Manager → External Secrets → k8s Secret | an **env var** in a pod |
| **B — Login users** | RisingWave SQL users and groups | Secrets Manager → External Secrets → bootstrap Job | a **RisingWave user** with a password |
| **C — Connector** | Kafka, Mongo, source-database credentials | Secrets Manager → `secret.yaml` workflow → `CREATE SECRET` | a **RisingWave SECRET object**, encrypted in the meta store |
| **D — By hand** | licence key, Dex client secret | typed into Secrets Manager directly | an env var, like flow A |

Non-secret configuration is a fourth thing again and does not belong in Secrets Manager at
all: hosts, ports, database names, topic names and schema names live in a ConfigMap, in
`risingwave-pipeline` at `deploy/overlays/<env>/endpoints.yaml`.

---

## Flow A — Platform secrets

1. `iaac-risingwave-onprem/deploy/terraform/secrets.tf` declares the Secrets Manager record.
2. It is applied **through Octopus only**. A local `terraform apply` is never the route.
3. An ExternalSecret in the `risingwave` namespace maps the record's properties to keys in a
   Kubernetes Secret.
4. The pod references those keys with `secretKeyRef`, and they resolve to env vars **at pod
   creation**.

Step 4 is the one that surprises people. Changing a value in Secrets Manager does nothing to
a running pod, and a crashlooping container replays the **old** value indefinitely. After any
value change the pod must be **deleted and recreated**, not restarted in place.

## Flow B — RisingWave login users

Passwords are stored as key/value secrets with the key `password`, one record per account,
e.g. `op-usxpress-dev/risingwave/svc-reporting`.

1. External Secrets syncs the passwords into the Secret `rw-service-account-credentials`,
   mapped in `rw-service-accounts-externalsecret.yaml`.
2. The bootstrap Job waits for the RisingWave frontend, logs in as `root` using
   `rw-root-credentials`, then creates any missing groups, creates or updates each login
   user, grants the group to the user, and applies the group's shared grants.

Groups are RisingWave users without passwords, used purely as grant targets. The active tiers
are `rw_readonly` and `rw_readwrite`, both granted against the `analytics` schema. Active
login users are `svc_reporting` (in `rw_readonly`) and `manager_user`. `svc_etl` and
`svc_app_backend` are defined but commented out.

**Status, measured 2026-09-01 on op-usxpress-prod:** the Job completes every group, user and
grant and then **crashloops on its last step** with `relation "anclax.users" does not exist`.
That table is the console's own schema, which only exists once the console has started, and
the console is down because of flow D. So the Job is idempotent for users and grants, and it
has never reached `Completed` on prod. Do not read this component as finished.

## Flow C — Connector secrets

This is the flow for Kafka, Mongo and source-database credentials. **These never become pod
environment variables.** They are stored inside RisingWave itself.

1. Values live in Secrets Manager, e.g. `op-usxpress-<env>/risingwave/kafka`.
2. The `Secret Manager` workflow — `.github/workflows/secret.yaml` in `risingwave-pipeline` —
   is a `workflow_dispatch` with `environment` (dev / qa / prod) and `connector`
   (kafka / mongodb / both) as inputs. It assumes an OIDC role, reads the record, and
   substitutes the values into the `%TOKEN%` placeholders in
   `pipelines/shared/000-secrets.rw`.
3. It runs the rendered file through `psql` against `rw-sql.op-<env>.usxpress.io:4567`:

       DROP SECRET IF EXISTS kafka_api_key;
       CREATE SECRET kafka_api_key WITH ( backend = 'meta' ) AS '<value>';

   Twelve objects: nine from the AWS record, three literals in the file. The `DROP … IF
   EXISTS` makes the whole file **idempotent** — it can be re-run at any time.
4. RisingWave encrypts each value with `secret_store_private_key` and stores it in the meta
   store. The pipeline DDL then references it by name:

       properties.sasl.password = secret kafka_api_secret,
       schema.registry.password = secret kafka_schema_registry_api_secret

So nothing sensitive appears in Git, in the image, or in a pod's environment. Verify by
listing, not by exit code: `SELECT name FROM rw_catalog.rw_secrets;` must return 12 rows.

**`CREATE SECRET` does not require a premium licence.** Twelve were created on QA on
2026-09-11 while that environment's licence key held a placeholder. The licence gates the
console UI and `CdcTableSchemaMap`, not secret management.

**Status, 2026-10-08:** the mechanism is proven; the automation is not. QA's twelve secrets
were created by running the same DDL with the same values by hand
(`scripts/rw-create-kafka-secrets.sh qa`, verified by listing 12 rows). The workflow itself
assumed the wrong OIDC role — `…-risingwave-pipeline-secrets`, which is scoped to
`/risingwave-2/*` and is dev-only — instead of the `…-risingwave-poc-secrets` role scoped to
`/risingwave/*`. `risingwave-pipeline` #32 corrected the role. **No successful run of this
workflow has been observed in any environment.** Confirm one before describing it as the
durable path.

## Flow D — Set by hand

Two values are not managed end to end by Terraform and must be written into Secrets Manager
directly:

- **`console_license_key`** — Terraform creates the record with `ignore_changes`, so a real
  licence written by hand survives later applies. Format is `{"RW_LICENSE_KEY": "<jwt>"}`.
- **`dex_entra_client_secret`** — not declared in Terraform at all. One per environment, and
  the Entra app registration is **shared** across dev/QA/prod (`e112d6ce-…`), so a new
  environment is a redirect-URI addition plus a copied secret, not a new identity.

---

## AWS Secrets Manager inventory

Region `us-east-2`, one set per account: dev `700736442855`, QA `527101283767`,
prod `937464026810`.

| Secret ID (`op-usxpress-<env>/risingwave/…`) | properties | flow | consumer | status |
|---|---|---|---|---|
| `root` | `password` | A/B | SQL connection as `root` | exists dev/QA/prod |
| `postgres` | `username`, `password` | A | RisingWave meta store | exists dev/QA/prod |
| `svc-reporting` | `password` | B | `svc_reporting` login | exists QA/prod |
| `secret_store_private_key` | key material | A | encrypts every flow-C secret | exists QA/prod |
| `console_license_key` | `RW_LICENSE_KEY` | D | RisingWave Console | **placeholder on QA and prod** |
| `kafka` | `kafka__api_key`, `kafka__api_secret`, `kafka__bootstrap_server`, `kafka__rest_endpoint`, `kafka__resource_id`, `kafka__service_account`, `kafka__schema_registry_endpoint`, `kafka__schema_registry_api_key`, `kafka__schema_registry_api_secret`, `kafka__group_id_prefix` | C | Kafka/Avro connector | exists dev + QA; **prod not verified** |
| `entity-postgres` | `username`, `password` | C | application PostgreSQL for `.sql` files | **does not exist** — see below |
| `mongodb` | `connection_string`, `username`, `password` | C | Mongo connector | **not verified in any environment** |
| `manager_user` | `password` | B | `manager_user` login | **not verified** |

### `entity-postgres` does not exist

Measured on op-usxpress-qa: the ETL ExternalSecret requested five keys and three resolved.
`entity-postgres/username` and `entity-postgres/password` were never created. ESO reported
`SecretSyncedError` **and still wrote a partial Secret**, so the Secret looked populated; the
pod reached container creation and died there with `RESTARTS 0`, invisible to restart alerts,
for seven days.

The application database this secret authenticates to does not exist yet either, which is why
`POSTGRES_SERVER` is empty and why the pipeline's `300-transform.sql` and `400-sink.rw` are
deliberately in `EXCLUDE_RE`. **A missing credential here means a missing system, not a
missing secret.** Creating the record without the database produces a pod that starts and
then exits 1.

### Key casing differs between environments

Dev's properties are `KAFKA__…`. QA's are `kafka__…`. The table above shows QA's. Any code
that reads one casing silently gets **nothing** from the other — a candidate cause of
`secret.yaml`'s failed run on 2026-09-02. Check the casing in the target account before
running anything against a new environment.

---

## How to verify — and what is not evidence

| claim | **not** evidence | evidence |
|---|---|---|
| the secret synced | `SecretSynced=True` | list the Secret's keys and count them |
| the value is valid | a green ExternalSecret | the consumer accepts it; e.g. the console starting |
| the pod has the new value | the Secret is correct | the pod's `startTime` is after the change |
| the connector secrets exist | the workflow's exit code | `SELECT name FROM rw_catalog.rw_secrets;` returns 12 |
| the pipeline works | a row count | `GroupAuthorizationFailed: 0` in the compute log |

ESO writes the keys it **can** resolve. A single missing property still produces a Secret
that looks populated and a pod that dies at container creation. Count keys.

## How this fails silently

- **A green sync is not a valid value.** On 2026-09-01 `rw-license-key` reported
  `SecretSynced=True` within four minutes holding `PLACEHOLDER_INJECT_REAL_LICENSE`. The
  console rejected it: `license verification failed: license must be a compact JWT`. A real
  licence has three dot-separated parts and starts `eyJ`; the placeholder is one part.
- **An empty string reads as configured.** QA's three `schema_registry_*` properties existed
  and were empty for weeks. `CREATE SECRET` made empty secrets and the Avro decode failed far
  downstream. Fixed by copying the account-level `dx--ccloud-schema-registry-master`, which is
  the house convention — those credentials are managed in `variant-inc/iaac-confluent-cloud`
  and copied per consumer, not minted per environment.
- **A placeholder that satisfies a validator is worse than a blank.** Setting
  `KAFKA_SCHEMA_REGISTRY_MESSAGE: unknown` passes the pipeline's non-empty check and then
  fails inside RisingWave at decode time. A blank fails loudly.
- **`secret_store_private_key` is load-bearing.** It decrypts every flow-C secret. If a
  Terraform run ever regenerates it, all twelve Kafka secrets become unreadable and the
  symptom presents as bad Kafka credentials. Confirm `ignore_changes` covers it before any
  apply that touches `secrets.tf`.

## Known gaps, 2026-10-08

1. **No real console licence in any environment.** QA and prod hold the identical 52-character
   placeholder. The prod console crashloops, which also blocks the `anclax` schema and the
   bootstrap Job's final step. One licence covers the whole on-prem estate. Owner: Steve/Zach.
2. A RisingWave licence expiring **2026-11-01** was found on 2026-10-06 with nothing alerting
   on it.
3. **`secret.yaml` has never been observed completing a run.** Three one-line fixes were
   merged; a successful run has not been confirmed.
4. **Two mechanisms create users.** The platform bootstrap Job and the pipeline's
   `user-access-deploy.yaml` both reconcile the same user set, and the pipeline workflow is
   described as preferred "going forward" while the Job still runs. Two idempotent reconcilers
   over one user set will diverge. This needs a single owner.
5. `entity-postgres`, `mongodb` and `manager_user` are unproven — see the inventory.

---

## Extension steps

### Add a login user (flow B)

1. Create `op-usxpress-<env>/risingwave/svc-<name>` with the key `password`.
2. Add the mapping to `rw-service-accounts-externalsecret.yaml`.
3. Add the user to the `users` list in `rw-service-accounts-bootstrap-job.yaml`, in the right
   group.
4. Confirm by logging in as that user, not by the Job's exit status.

### Add an access tier (flow B)

1. Add the tier to the `groups` list.
2. Add its schema and table grants under `group_grants`.
3. Move or add users into the group.

### Add a connector secret (flow C)

1. Create `op-usxpress-<env>/risingwave/<connector>` — **matching the casing already used in
   that account.**
2. Add `DROP SECRET IF EXISTS` + `CREATE SECRET … WITH ( backend = 'meta' )` to
   `pipelines/shared/000-secrets.rw`, using a `%PLACEHOLDER%` token.
3. Teach `secret.yaml` to fetch and substitute the new property.
4. Run the workflow **once per environment** — there is no promotion between them.
5. Confirm with `SELECT name FROM rw_catalog.rw_secrets;` and check the new name is listed and
   the count went up by the number you added.

### Rotate any secret

1. Write the new value into Secrets Manager.
2. For flows A, B and D: **delete the pod**. The env var resolved at creation and a restart
   replays the old value.
3. For flow C: re-run `secret.yaml` — the file is idempotent — then re-list `rw_secrets`.
4. Confirm at the consumer. For Kafka, the finish line is `GroupAuthorizationFailed: 0` in
   the compute log, not a green sync.

---

## What changed in this revision

- Split one described flow into the four that actually exist, because they have different
  owners and different failure modes.
- `entity-postgres` moved from "existing record" to "does not exist", with the measurement.
- Added `secret_store_private_key`, `console_license_key` and `dex_entra_client_secret`, which
  were absent — the three that have caused the outages on this subject.
- Noted that property casing differs between dev and QA.
- Corrected "the Job is idempotent" to say what is idempotent and that it has never completed
  on prod.
- Marked `secret.yaml` as unproven rather than operational, and recorded that QA's connector
  secrets were created by hand.
- Added verification criteria, since a green ExternalSecret has twice been mistaken for a
  working credential.

# Confluent Cloud request — schema-registry access for QA (and prod)

**Raised 2026-09-11 by Dare Oke.** Needs a Confluent Cloud administrator.
Blocks the RisingWave Brand pipeline cutover on op-usxpress-qa.

## What is wrong

QA's RisingWave can reach Kafka but **cannot reach the schema registry**. In
`op-usxpress-qa/risingwave/kafka` (AWS Secrets Manager, us-east-2, account usx-qa) six of
nine fields are populated and three are empty strings:

    kafka__api_key                     set
    kafka__api_secret                  set
    kafka__bootstrap_server            set
    kafka__rest_endpoint               set
    kafka__resource_id                 set
    kafka__service_account             set
    kafka__schema_registry_endpoint    EMPTY
    kafka__schema_registry_api_key     EMPTY
    kafka__schema_registry_api_secret  EMPTY

`pipelines/Brand/100-sources.rw` is `FORMAT PLAIN ENCODE AVRO`, so it cannot decode a
single message without the registry.

## What we need

**A schema-registry API key for QA's EXISTING service account** — not a new identity:

| | |
|---|---|
| service account | `sa-81m660q` (QA) |
| Kafka cluster | `lkc-19mn63` |
| schema registry | `psrc-yorrp.us-east-2.aws.confluent.cloud` — the same registry dev uses |
| access needed | **read** on the registry; the QA subject `qa_brand_management_cdc_brand_avro-value` already exists there |

Plus the role binding that lets that service account read the registry — a key without
the binding authenticates and then returns 403, which looks identical to a wrong key.

**Please do the same for prod at the same time.** `op-usxpress-prod/risingwave/kafka`
**does not exist at all** — dev and QA both have one, prod has none. Better to find that
out now than during the prod cutover.

## Why not just copy dev's key

It would work today. It also puts one credential in two environments, which is the exact
thing INFRA-1637 has spent a month undoing. We chose the slower, correct route.

## How we will verify it (not by "the key exists")

    bash scripts/verify-qa-schema-registry.sh

Lists the registry's subjects with the new credential and reads the Brand schema back. A
key that authenticates is not a key that is authorised — the script separates 401 from 403
from 200-with-nothing.

## Once it lands

1. Doke writes the three values into `op-usxpress-qa/risingwave/kafka`.
2. Verify with the script above.
3. Idris runs the `secret.yaml` workflow against QA, then confirms the nine `kafka_*`
   RisingWave SECRET objects exist **by listing them**.
4. `risingwave-pipeline` #29 merges and the Brand cutover runs.

---
name: rw-kafka-sa-lacks-group-binding
description: "RisingWave consumes Confluent as unmanaged sa-81m660q, which has topic read but NO consumer-group authorization"
metadata:
  type: project
---

RisingWave's Kafka sources authenticate as **`sa-81m660q`** (from
`op-usxpress-<env>/risingwave/kafka` `.kafka__service_account`; QA cluster `lkc-19mn63`). That
account is **not** the one `variant-inc/iaac-confluent-cloud` creates — that repo makes
`iaac--<env>-<name>-cluster` and gives it `CloudClusterAdmin` on the cluster plus
`ResourceOwner` on `subject=*`. It declares **no consumer-group binding for anyone else**.

Verified live on QA 2026-09-11: cluster auth works and topic read works (watermarks fetched,
batch scan clean), but the streaming reader loops on
`GroupAuthorizationFailed (Broker: Group authorization failed)`. The source takes its group
from `secret kafka_group_id_prefix` = `<env>_kafka_prefix` (prod is `prodkafka_prefix`, no
underscore).

**Why it matters:** the symptom is an empty materialized view, which reads exactly like an
empty topic. It is an authorization gap, not a bad credential — do not rotate keys chasing it.

**How to apply:** the fix is `DeveloperRead` on `group=<env>_kafka_prefix*`, declared in
`iaac-confluent-cloud` as a generic binding variable. **Do not** "fix" it by moving RisingWave
onto the managed account — that account holds `CloudClusterAdmin`, so an ETL consumer would
gain the right to delete topics. Least privilege beats tidiness here.
Related: [[ccloud-registry-master-per-account]], [[rw-database-is-named-dev-everywhere]].

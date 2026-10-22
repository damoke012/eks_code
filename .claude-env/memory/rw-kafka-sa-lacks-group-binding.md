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

## ✅ RESOLVED 2026-10-09 — the grant landed and mv_brand is building

`ix-kafka-topics-users` **#303 merged** (approvals: jenni-ray, jshaw-usx). Jeff Shaw deployed
it to dev **before** merging, because that deploy is a required check on the PR
([[octopus-deploy-can-gate-the-pr]]).

Measured on op-dev at 16:40Z, through a port-forward to risingwave-frontend:

    sources:   2
    mviews:    7
    mv_brand:  9

And the applier that used to die on `CREATE MATERIALIZED VIEW mv_brand` now exits clean:

    Job/etl-pipeline-apply  hookType=Sync  hookPhase=Succeeded
    phase=Succeeded  start=16:36:10Z  end=16:36:24Z

**The whole diagnosis held.** The service account could read the topics and not join a
consumer group; the empty MV was authorisation, never a bad key, never the SQL. What cost the
time was not the diagnosis but reading the grant: the YAML says `prefix: risingwave` and the
module renders `dx__<env>_risingwave`, so I called the fix broken twice before reading the
Terraform ([[declared-grant-is-not-the-literal-acl]]).

**QA is NOT fixed.** Separate deployment of the same module, separate service account. QA's
grant does not exist until someone deploys that repo to QA — nothing gated it, so nobody did.

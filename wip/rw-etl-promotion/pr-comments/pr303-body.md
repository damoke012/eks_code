## Problem

`users/risingwave.yml` grants topic READ but has no `consumer_groups` block — every other
consuming user in this repo has one. Without it RisingWave cannot join a consumer group, so its
streaming sources fail continuously with `GroupAuthorizationFailed` while topic reads keep
succeeding. That asymmetry is why this presented as a credentials problem for longer than it
should have.

## Change

Five lines, following the shape used in `analyticsconsumer.yml`.

Per `deploy/terraform/users.tf:44` (`group = "dx__${local.prefix}${group.prefix}"`) and
`main.tf:4`, this renders:

| Confluent environment | granted group prefix |
|---|---|
| qa (`confluent_prefix = qa`) | `dx__qa_risingwave*` |
| production (empty prefix) | `dx__risingwave*` |

## Which environments this touches

`development` / `qa` / `production` here are **Confluent environments**. In every case the
consumer is **on-prem RisingWave**, running on `op-usxpress-dev` / `-qa` / `-prod` and
connecting out to Confluent. So the ACL objects are created in the Confluent estate, while the
workload consuming them is not cloud-hosted.

**No cloud-hosted producer or consumer is affected in any environment.** Nothing existing is
modified; the new grant is scoped to a group prefix only RisingWave uses.

## Scope

- One additive `ALLOW READ` ACL on a `GROUP` prefix per environment, for the
  `dx__<env>_risingwave` service account this repo already creates.
- No existing ACL modified or removed. No topic touched.
- All 20 `consumer_groups` prefixes across `users/*.yml` are distinct — no `for_each` key
  collision.
- `deployed_in: others` matches 17 of the 20 existing entries.

## Verified before raising

- On `op-usxpress-qa`, `risingwave-compute-default-0` logs
  `GroupAuthorizationFailed (Broker: Group authorization failed)` every ~2s for
  `source_name="kafka_brand"` — while the *same* run fetches Kafka watermarks successfully.
  Cluster auth and topic read work; only the consumer group is denied.
- The consumer's group prefix is read from Secrets Manager (`risingwave-pipeline#31`) and set
  to `dx__qa_risingwave`, so it matches exactly what this grants.

## Note for the Confluent production deploy

This file deploys to every Confluent environment, so a production deploy will also create
`dx__risingwave*` on `lkc-j8n7j8`. Additive, consumed by on-prem RisingWave in
`op-usxpress-prod`, and the intended end state — flagging it rather than letting it surprise
anyone.

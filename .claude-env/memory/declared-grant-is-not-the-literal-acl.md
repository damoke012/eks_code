---
name: declared-grant-is-not-the-literal-acl
description: "A grant written in an IaC source file is not the string the cloud enforces — ix-kafka-topics-users prepends dx__ and the environment, so `prefix: risingwave` renders as `dx__dev_risingwave`; compare the RENDERED name, never the declared one"
metadata:
  type: project
---

**2026-10-08, `variant-inc/ix-kafka-topics-users` PR #303.** RisingWave's dev ETL failed
`CREATE MATERIALIZED VIEW mv_brand` with `GroupAuthorizationFailed`. `users/risingwave.yml`
had `topics:` and **no `consumer_groups:` section at all**; PR #303 adds one and has sat
OPEN / `REVIEW_REQUIRED` since September.

**I twice declared #303 broken because its prefix did not match.** The YAML says
`prefix: risingwave`; the live consumer groups are `dx__dev_risingwave` and
`dx__qa_risingwave`. Neither starts with `risingwave`, so the grant looked like a no-op, and
I recommended first widening it to `dx__` and then renaming our own group prefix.

**Both recommendations were wrong.** `deploy/terraform/main.tf:43` and `users.tf:44` build the
ACL name themselves:

    prefix = "dx__${local.prefix}${group.prefix}"       # local.prefix = "<confluent_prefix>_"

So `risingwave` renders as `dx__dev_risingwave` in dev and `dx__qa_risingwave` in QA —
exactly the live group prefixes. `resource_type = "GROUP"`, `pattern_type = "PREFIXED"`,
`operation = "READ"`. **#303 is correct as written.**

The same decoration explains a thing that had looked wrong and wasn't: the file grants topic
`brand_management` PREFIXED while dev consumes `dev_brand_management_cdc_brand_avro`.
`main.tf:55` prepends `local.prefix` there too.

**How to apply.** Before calling an IaC grant wrong because its string does not match the live
resource, **find where the module composes the name** and compare the *rendered* value. Grep
the locals for the declared field — here `group.prefix` and `topic.name` — and read every
interpolation that consumes it. A declared identifier is an input to a naming function, not
the name. Same family as [[computed-value-never-consumed]] and [[proxy-is-not-the-property]]:
I compared something adjacent to the property and reported it as the property, twice, in
consecutive turns.

**Two further facts from the same read.**

* `local.users` keys on `dx__${local.prefix}<filename>` and `secrets.tf:4` strips the prefix
  back off, giving one `dx__risingwave-kafka-creds` secret per AWS account. Dev and QA are
  **two separate deployments of one module**, each minting its own `risingwave` service
  account — which is why their `service_account` ids differ (sha8 `d2fac222` vs `19b54c68`)
  while both come from the same user file. One merge covers both environments.
* `used_by.deployed_in` (`others` / `azure` / `octopus`) is **metadata only** — zero consumers
  anywhere outside `users/*.yml`. It does not gate which environment receives a grant.

**Trap for prod.** With an empty `confluent_prefix` the same grant renders `dx__risingwave`,
so prod's `kafka__group_id_prefix` must equal that or prod repeats this failure.

**Merging is not applying.** `connect.tf` carries `cloudops.io.octopus/environment` tags — the
module runs through Octopus per environment, so the ACL exists only after a deploy.
Same shape as [[octopus-green-but-no-apply]].

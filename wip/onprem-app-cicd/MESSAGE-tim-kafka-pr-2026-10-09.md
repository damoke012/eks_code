# Message to Tim — closing the Kafka consumer-group PR (drafted 2026-10-09)

Audience: Tim Preble. He cannot approve or deploy this himself; the point is that he
understands why his MVs fail and can push from the business side if he knows someone.

---

The thing blocking your materialized views is one Kafka permission, and the fix is a PR
that's been open since September: ix-kafka-topics-users #303.

Why it's needed: the RisingWave service account is allowed to read the topics but not to
join a consumer group. A streaming read needs a consumer group, a plain query doesn't -
which is why `CREATE SOURCE` works, `SELECT * FROM kafka_brand LIMIT 1` works, and
`CREATE MATERIALIZED VIEW` fails with GroupAuthorizationFailed. Nothing wrong with your SQL.

Two things have to happen, in order:

1. Someone in engineering-leadership approves it. They own the users/ directory in that repo,
   so my approval doesn't count and I can't approve my own PR anyway.
2. After it merges, that repo gets deployed through Octopus - once for dev, once for QA.
   The merge on its own creates nothing in Confluent. A release built from this branch in
   September was never deployed, which is part of why it's still sitting there.

It affects dev and QA both, same cause in both.

If you know anyone on the Kafka or data platform side who can approve it, a nudge from you
would probably move it faster than one from me.

---

## Not said, deliberately

- That I am the PR's author. Irrelevant to him and it makes the ask sound personal.
- The ACL prefix rendering detail (dx__ + environment). He does not need it and it invites
  a correctness debate he cannot settle.
- That I called the PR broken twice yesterday before reading the Terraform. Mine to carry.

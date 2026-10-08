# Message: Confluent credential rotation needed (drafted 2026-10-08, NOT YET SENT)

Audience: whoever owns Confluent Cloud IaC (`variant-inc/iaac-confluent-cloud`) and
`variant-inc/ix-kafka-topics-users`, plus cloudops. Send in a channel or direct message, not
as a wide broadcast — it names an exposure and the fewer hops it takes the better.

Deliberately contains no credential values, no fragments and no hashes.

---

Four live Confluent credentials were sent to me in plaintext over email today and need
rotating. No evidence of misuse — raising it because the email path is outside our control
and the credentials are shared, not per-environment.

The four:

  KAFKA_SASL_USERNAME and KAFKA_SASL_PASSWORD
  KAFKA_SCHEMA_REGISTRY_USERNAME and KAFKA_SCHEMA_REGISTRY_PASSWORD

These are copies of two per-account master secrets, not application-specific values, so the
exposure reaches every consumer of those masters rather than one app:

  dx__risingwave-kafka-creds          created by ix-kafka-topics-users (secrets.tf)
  dx--ccloud-schema-registry-master   one per AWS account, consumers copy from it

Two different owners as far as I can tell, so this is probably two pieces of work:

  the Kafka API key and secret  -> ix-kafka-topics-users has a rotation_function.tf and
                                   per-user rotation blocks, so there may already be a
                                   mechanism here. I have not verified it covers this user.
  the schema registry pair      -> iaac-confluent-cloud

What I need to know:

  1. Who rotates each of the two, and is there an existing runbook or does the rotation
     function handle it.
  2. What else reads those masters. Anything copying from them needs the new value, and I
     would rather enumerate consumers before the rotation than discover them after.
  3. Whether rotating affects the RisingWave ETL pipeline on on-prem dev and QA. Those read
     op-usxpress-<env>/risingwave/kafka, which I believe is a copy, so it would need
     re-copying and the Secret Manager workflow re-running per environment.

Happy to do the on-prem side of it once I know who owns the upstream half.

---

## Why this is worth sending even though nothing is known to be compromised

The credentials are **shared masters**. The blast radius is not "one developer's local
docker-compose" but every consumer in the account, and the exposure happened on a path with
no audit trail we control. A rotation is cheap; finding out later that it should have
happened is not.

## The process half, which is ours not his

Key **names** were asked for and **values** came back. The ask did not say why, so there was
nothing in it to make a developer pause before pasting a `.env`. Any future request for
configuration must carry the reason in the same breath:

> "Send me the key NAMES only, not the values — if a value lands in email or a ticket it has
> to be rotated, and these are shared across every consumer in the account."

Recorded in [[secret-and-owner-are-two-axes]].

## Status

Drafted 2026-10-08. **Not sent.** Needs the recipient list confirmed before it goes anywhere.

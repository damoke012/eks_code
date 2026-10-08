Tim - got your .env, here is the split.

Your three sections are right but there are two questions per key, not one. Who owns it, and
is it a secret. That gives four buckets:

1. Platform, not secret - hosts, ports, bootstrap server, security protocol, registry
   endpoint. Goes in a ConfigMap per environment, we own the PR.
2. Platform, secret - Kafka api key/secret, schema registry key/secret, Postgres and root
   passwords. Already in AWS Secrets Manager, nothing for you to do.
3. Developer, not secret - topic names, startup mode, schema message, entity schemas, Mongo
   database and collection names. Same ConfigMap, you own the PR.
4. Developer, secret - CDC user and password, entity Postgres user and password. Send me the
   key names only and I will write the values in once.

Your Kafka credentials are already there - op-usxpress-<env>/risingwave/kafka, nine keys. Do
not put them in the file.

Three things from your side:

The image version pins are Docker only, drop them for the cluster - versions are pinned by
digest in the overlay.

RW_META_SECRET_STORE_PRIVATE_KEY and RW_SECRET_STORE_PRIVATE_KEY_HEX have a space before the
= so the key parses with a trailing space and matches nothing. Those two are what RisingWave
uses to read back its own secrets.

The Entity: Truck header has no keys under it, and Brand's four keys sit under the template
header.

The secret syntax is secret <name>, not a bang - properties.sasl.password = secret
kafka_api_secret. And 000-secrets.rw already creates them, it is idempotent, you do not need
to build that part.

Four questions: is it scan_startup_mode or KAFKA_STARTUP_MODE that your SQL reads, what does
RW_HOST_NAME do that RW_HOST doesn't, can RW_IN_CONTAINER be hardcoded true, and what
consumes DB_ANON_ROLE.

One correction from the call - you can't call the External Secrets Operator from Docker, it
only runs in Kubernetes. Idris's script is the right path for local.

Dev first, then QA, then prod. Not all three today.

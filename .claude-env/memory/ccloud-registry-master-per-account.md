---
name: ccloud-registry-master-per-account
description: Confluent schema-registry creds live in ONE secret per AWS account (dx--ccloud-schema-registry-master); consumers copy it — never mint a second key
metadata:
  type: project
---

**Confluent Cloud schema-registry credentials are one secret per AWS account:**
`dx--ccloud-schema-registry-master`, holding `KAFKA__schema_registry_endpoint`,
`_api_key`, `_api_secret`. Every consumer copies those three values into its own secret.
No per-app `dx__<app>-kafka-creds` carries registry fields — they are seven keys, Kafka
only.

Proven 2026-09-11: `op-usxpress-dev/risingwave/kafka` holds values byte-identical to
dev's master (sha256 compare). QA's were empty, which is why the Brand Avro source could
not decode. `scripts/copy-registry-creds-to-rw.sh <env>` does the copy, casing-aware —
the master is `KAFKA__`, on-prem QA's target is `kafka__`.

Confluent itself is managed in **`variant-inc/iaac-confluent-cloud`** (OpenTofu via
Octopus): environments, clusters, service accounts, `confluent_api_key.schema_registry`,
and `confluent_role_binding.schema_registry_rw` (ResourceOwner on `subject=*`). Topics
live in `ix-kafka-topics-users`; Avro schemas in `ix-kafka-schema-registry`.

**Why this matters:** the reflex when access is missing is to find someone who can grant
it. I had drafted a request to a Confluent admin and built a wizard to mint a new key —
which would have created a *second* credential for a service account that already had
one, during a project (INFRA-1637) about reducing credential sprawl.

**How to apply:** before asking who can grant access, run `gh repo list <org>` and find
how the organisation already grants it. One command beat a day of waiting on an admin.
See [[onprem-gitops-repo-topology]], [[two-projects-one-resource]].

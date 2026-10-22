---
name: missing-credential-may-mean-missing-system
description: A "missing secret" error can mean the system it authenticates to does not exist; check the endpoint config before creating the credential
metadata:
  type: feedback
---

**Before creating a missing credential, check that the thing it authenticates to exists.**

2026-09-10, op-usxpress-qa: the ETL apply Job had been in `CreateContainerConfigError` for
nine days on `couldn't find key POSTGRES_ENTITY_USER`. Everyone — me included — read that as
"the Secrets Manager records were never created", and the fix went on the critical path as a
Terraform change plus an Octopus deploy, blocking two PRs.

The cluster said otherwise. In `app-risingwave/etl-pipeline-endpoints`, **`POSTGRES_SERVER`
and `POSTGRES_ENTITY_DB` are empty strings**. There is no application database in QA at all —
three services listen on 5432 and all three are RisingWave's own. The credential had no
server to connect to. Creating it would have produced a pod that starts and then exits 1 on
the blank host the first time a `.sql` file appeared.

**Why:** the error names the key that is missing, and a named key invites you to supply it.
It never names the absence behind it. Same family as [[proxy-is-not-the-property]] — the
message is a true statement about the wrong layer.

**How to apply:** when a Secret key is missing, read the ConfigMap or values that say **where
that credential is used** before creating it. If the endpoint is blank, the fix is to stop
demanding the credential (drop it from the ExternalSecret and mark the env `optional`), not
to invent one. See [[eso-writes-partial-secrets]], [[adjacent-step-green-signals]].

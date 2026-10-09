# Message to Tim — dev is live (drafted 2026-10-08)

Audience: Tim Preble. Plain lines, no headers, nothing he has to act on except the values file.

---

Dev is wired up and running.

To deploy: merge to master in risingwave-pipeline. That's the whole thing. Argo CD picks it
up and runs your SQL against RisingWave on op-dev within a couple of minutes. No Octopus, no
ticket, nothing to ask us for.

Secrets - you don't handle any of them:

- RisingWave and Postgres passwords go from AWS Secrets Manager straight into the job's
  environment. They are never in the repo.
- Kafka and schema registry credentials are created inside RisingWave by a workflow. Your SQL
  just names them, like `secret kafka_api_key`.
- The non-secret settings from your .env - topic, startup mode, schema registry message - now
  live in deploy/chart/values-dev.yaml. Those are yours to change in a PR.

Still blocking: materialized views fail with a Kafka consumer group authorization error.
Sources create fine, the MV doesn't. PR #303 on ix-kafka-topics-users grants it - once that
merges and deploys, mv_brand should build. It isn't your SQL.

One favour: if you send us config, send key names only, never values. Anything that reaches
email has to be rotated, and those Kafka keys are shared by every consumer in the account.

---

## Not said, deliberately

- QA and prod are not on this path yet. Saying so invites "when?", and the honest answer
  depends on #303 and on QA's own values file. Raise it when dev produces rows.
- Helm, the chart, the ApplicationSet, Flux. He does not need the delivery mechanism to use
  it, and naming it invites questions that change nothing for him.
- That the ACL has also been missing on QA since September. True, and not his problem.

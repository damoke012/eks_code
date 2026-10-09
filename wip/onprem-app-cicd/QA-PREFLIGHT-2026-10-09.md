# Promoting the RisingWave ETL to QA — pre-flight

Measured 2026-10-09 evening, after dev was completed end to end. Nothing in QA was
changed to produce this. Dev needed **nine** separate handoffs fixed, every one of
which failed GREEN; this is each of them re-asked of QA.

**QA is healthier than it looks.** Its Argo Application already reads `deploy/chart`
at `master`, `etl-pipeline-credentials` is SecretSynced with 3 of 3 keys, the digest
is pinned, and the sync hook Succeeded at 22:17:17Z. QA is on Helm **today** — an
earlier claim in this workstream that it ran the kustomize overlay was wrong, and came
from a check that reported FAIL against an expired SSO session.

## Closed already — no QA action

| # | Gate | Evidence |
|---|---|---|
| 1 | Cross-org build reaches ECR | published reusable workflow, OIDC only |
| 2 | ECR repository policy | **fixed 2026-10-09**: dev + QA + prod accounts, read-only, on `risingwave/poc-pipeline` |
| 3 | A dead `EXCLUDE_RE` validates silently | guard merged in BOTH `apply.sh` copies (pipeline #94, cicd #3) |
| 4 | Argo reads the chart | `path=deploy/chart rev=master` |
| 5 | Credential present and usable | 3 of 3 keys, SecretSynced |

## Open — do these BEFORE promoting

1. **Decide which image QA runs.** `apps.json` pins `ecr: risingwave/poc-pipeline`
   (Tim's). QA runs `risingwave/etl-pipeline` (ours) today, fed by `promote-to-qa.yml`
   on a `*/10` cron. Enabling `qa` in `apps.json` IS the switch — there is no
   content-neutral version. Tim must confirm his repo carries QA's pipeline: QA runs
   **Brand/Avro**, his dev work is **Employee/JSON**.

2. **Retire `promote-to-qa.yml`** — but only AFTER 1. It writes `values-qa.yaml` *and*
   both overlay files. Leaving it alongside `promote.yml` puts two writers on one file,
   from two different ECR repositories.

3. **Rewrite QA's `EXCLUDE_RE` for whichever layout wins.** Ours is `pipelines/Brand/`;
   Tim's is `100-Brand/` and `300-Employee/`. QA's current regex has a dead alternative
   already (`employee`, lowercase, matches nothing). If QA switches image and the regex
   is not rewritten, EVERY alternative goes dead.

4. **Set `EXCLUDE_STRICT: "true"` on QA.** Only dev sets it. Without it a dead regex
   warns and continues — which is how dev validated 27 values for files it was not
   applying.

5. **QA has no `entity` secret and no `mongodb` secret.** Dev gained both tonight
   (`op-usxpress-dev/risingwave/{entity,mongodb}`). QA's list: console_license_key,
   dex_entra_client_secret, kafka, postgres, root, secret_store_private_key,
   svc-reporting. Needed only if QA runs the Employee/Mongo pipeline — but needed
   BEFORE, not during.

6. **QA's `wal_level`.** Dev's is in the Helm chart (`#45`); QA and prod use StatefulSet
   args, a DIFFERENT mechanism, so dev proving it validates nothing for QA. Changing it
   restarts Postgres, which is RisingWave's meta store.

7. **QA's Postgres admin is not `postgres`.** A connection as `postgres` fails with
   `role "postgres" does not exist`. The bootstrap hook needs an admin that can CREATE
   DATABASE, create a REPLICATION role, and CREATE PUBLICATION FOR ALL TABLES — the last
   is superuser-only. NOT MEASURED whether QA's admin qualifies.

8. **Kafka consumer-group grant does not exist in QA.** `ix-kafka-topics-users` was
   deployed to dev only, because the dev deploy gates that PR and nothing gated QA.
   QA's materialized views stay empty until someone deploys it to the QA environment in
   Octopus. No code change. The ACL renders as `dx__qa_risingwave`, not `risingwave`.

9. **Nobody has read the destination.** Dev's Mongo collections have still not been
   opened. Do not accept a green sync as the finish line in QA either — finish at row
   counts in the target.

## Traps this environment has already sprung

* **An expired SSO session reads as absence.** The kubeconfig pins `AWS_PROFILE` in its
  exec env (`op-qa`), so `aws sso login` on any other profile changes nothing. Prove it
  with `kubectl get --raw /version` before believing any result.
* **Two copies of `apply.sh`.** Dev runs the `iaac-risingwave-cicd` one via
  `FROM sql-applier`; QA and prod run `risingwave-pipeline`'s own. A behaviour measured
  on dev is not evidence about QA.
* **`-z` cannot tell unset from empty.** A values comment claimed two keys had to be
  "present-and-empty, not omitted". Both are identical to `apply.sh`; PR #98 removes them.
* **Prod has ZERO Argo Applications.** Not partially wired — unwired. `values-prod.yaml`
  does not exist on master; PR #84 holds a first-pass version and also touches a shared
  template, so it affects dev and QA too.

## Proven / tested and killed / not verified

**Proven:** QA is on the chart and applying SQL successfully as of 22:17:17Z 2026-10-09.
The ECR policy now admits all three cluster accounts. The dead-regex guard exists in both
applier copies.
**Tested and killed:** that QA runs the kustomize overlay (it does not); that
`values-qa.yaml`'s two empty keys were load-bearing (they are inert).
**Not verified:** QA's `wal_level`; whether QA's Postgres admin is superuser; whether
Tim's repo carries a QA Brand pipeline; any document in any Mongo collection, in any
environment.

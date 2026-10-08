Looked at #41. Good catch measuring the actual values, that table is the right place to start.

Hold the merge, there's one thing to settle first and it might mean we don't need the change
at all.

pg-postgresql in the risingwave namespace is RisingWave's own meta store, it only holds
catalog and cluster metadata. Tim wants CDC so RisingWave can ingest change data and his
sources are SQL Server. If that's right, logical replication on the meta store gives him
nothing, and SHOW wal_level would return logical either way so the test would still pass.

1. Ask Tim which database he needs change capture from. If it's SQL Server, close #41 and we
open a ticket for CDC on the actual source instead. That's a different piece of work, enabling
it on the SQL Server side plus a RisingWave source connector.

If he does want it on this PG, then:

2. Split #41 into three PRs, one per manifests/op-usxpress-<env>/ dir. The test plan can't run
as written, every cluster tracks main at 5m so one merge hits dev QA and prod inside five
minutes and there's no point in between to check anything. Merge dev, verify, then QA, verify,
then prod.

3. Before writing the QA and prod PRs, check the arg actually reaches postgres and that the
StatefulSet will take the edit:

kubectl --context admin@op-usxpress-qa -n risingwave get sts pg-postgresql \
  -o jsonpath='{.spec.template.spec.containers[0].command}{"\n"}{.spec.template.spec.containers[0].args}{"\n"}'

The Bitnami entrypoint is a wrapper, appending to args only works if it passes them through.
And a rejected dry run fails the whole Kustomization not just that object, that's what froze
this namespace for 4h on #36.

4. On dev after the merge, get the evidence that prod needs later. Meta pod restart count, the
reconnect line in its log, and a query served after. Reconnects automatically is the claim the
prod change rests on and right now it's an expectation. No Alertmanager on prod if it's wrong.

5. Ignore the two red checks, don't spend time on them. dpl has failed 7/7 since August with
zero successes ever, Terraform Validate 5/5 since September including PRs that merged. Neither
is about your change. Both need their own tickets though, a check that has never passed can't
tell a real break from the floor. Can you raise those two.

Full detail in a PR comment. Happy to pair on the split.

Much better — dev only, two lines, right mechanism for the Bitnami chart. Thanks for
splitting it.

Three lines above your diff in the same file:

    database: risingwave_meta

That is the question from #41, answered by the manifest. This PostgreSQL is RisingWave's
meta store. If Tim needs CDC so RisingWave can **ingest** change data, the source is his
database, not this one, and `wal_level = logical` here changes nothing for him.

**Has Tim confirmed which database?** If yes and it is this one, this is good to merge with
the two checks below. If he meant his SQL Server, close this and we open a ticket for CDC on
the real source instead.

Two things to verify after merge, because the PR can look done while nothing changed:

**1. Did the pod actually restart.** `extendedConfiguration` lands in a ConfigMap. The
StatefulSet only rolls if the chart puts a checksum annotation on the pod template, or
Reloader picks it up. If it does not roll, `SHOW wal_level` still returns `replica` and the
HelmRelease is Ready the whole time.

```
kubectl --context admin@op-usxpress-dev -n risingwave get pod -l app.kubernetes.io/name=postgresql \
  -o custom-columns='NAME:.metadata.name,START:.status.startTime,RESTARTS:.status.containerStatuses[0].restartCount'
```

The `startTime` has to be after the merge. Then `SHOW wal_level;` — and read it from a pod
whose start time you just checked, not from any pod.

**2. Did RisingWave reconnect.** This is the evidence QA and prod need later, so it is worth
capturing properly: the meta pod's restart count, the reconnect line in its log, and a query
served afterwards. "Reconnects automatically" is currently an expectation; after this merge
it can be an observation.

Ignore the two red checks. `dpl` has failed 7/7 since 2026-08-12 with zero successes ever,
and Terraform Validate 5/5 since 2026-09-15 including PRs that merged. Neither is about your
change — but both need their own tickets, since a check that has never passed cannot tell a
real break from the floor.

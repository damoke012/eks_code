Saw #42, that's the right shape. Dev only, two lines.

One thing though, three lines above your diff in the same file:

database: risingwave_meta

That's the #41 question answered by the manifest. This PG is RisingWave's meta store. Did
Tim confirm he wants CDC from this one? If he meant his SQL Server then this doesn't give
him anything and we should close it and ticket CDC on the real source.

If he did confirm, two things to check after merge or it'll look done without being done.

extendedConfiguration goes into a ConfigMap, so the StatefulSet only rolls if the chart puts
a checksum on the pod template or Reloader catches it. Check the postgres pod startTime is
after the merge before you run SHOW wal_level, otherwise you'll read replica off an old pod
and think the change failed.

And grab the meta pod restart count and its reconnect log line. That's the evidence QA and
prod need later, reconnects automatically is still just an expectation until dev shows it.

Red checks are still noise, ignore them.

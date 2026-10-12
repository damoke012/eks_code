Tim - dev is back, RisingWave is on 3.0.5 now.

Took about eight minutes. Everything came back on its own.

I checked your side specifically: all five of your materialized views are there,
all four sinks are there, the employee CDC slot is active again and the counts
match what they were before - 2 employees and 1 contact in both RisingWave and
the entities database.

Prod went first this morning and is also on 3.0.5. QA is the only one left.

Nothing for you to do. If anything looks off in your pipeline today, tell me and
I have a full backup of the metadata from just before the upgrade.

---
name: risingwave-mongodb-sink-facts
description: "RisingWave 2.8.2 DOES accept mongodb+srv Atlas URLs (the docs never say so); and a sink from any MV needs force_append_only because an MV is a retract stream"
metadata:
  node_type: memory
  type: reference
---

Measured on op-usxpress-dev, RisingWave **2.8.2**, 2026-10-09. Both answers are absent from
the documentation, which describes `mongodb.url` only as "The URL of MongoDB" and shows
nothing but `mongodb://host:27017/?replicaSet=rs0`.

## ✅ `mongodb+srv://` works

`CREATE SINK … mongodb.url='mongodb+srv://user:pass@<cluster>.mongodb.net/'` **succeeded**,
the sink appeared in `show sinks`, `rw_ddl_progress` stayed empty, and the compute log
(`risingwave-compute-default-0`) logged nothing about mongo. So the Rust driver resolves the
Atlas DNS seedlist from inside the cluster — CoreDNS forwards `.` to the node resolver and
SRV lookups are not blocked.

⚠️ `getent hosts <cluster>.mongodb.net` returning nothing is **expected** and proves nothing:
an SRV-only name has no A record, and `getent` cannot query SRV. Do not read that as a DNS
failure. The only real test is `CREATE SINK`, which validates at DDL time.

**Consequence for a developer's SQL:** an Atlas SRV string has **no port**, so
`mongodb://%USER%:%PASS%@%HOST%:%PORT%/` cannot be built from it. Take the whole string:

    mongodb.url = '%MONGODB_CONNECTION_STRING%'

`op-usxpress-dev/risingwave/mongodb` holds `MONGODB_CONNECTION_STRING`, `MONGODB_USERNAME`,
`MONGODB_PASSWORD` — and the connection string already carries the credentials.

## A sink from a materialized view needs `force_append_only`

    Invalid input syntax: The sink of retract stream cannot be append-only.
    Please add "force_append_only='true'" …

Every MV is a retract stream, so `type='append-only'` from an MV always fails until that
option is set — and setting it drops DELETEs and converts UPDATEs to INSERTs, which is a
data decision, not a syntax fix. Use `type='upsert'` with a `primary_key` when the
destination should track changes.

## How to probe safely

`CREATE SINK` validates the connection, so the statement itself is the test. Pick a relation
with few rows, name the collection obviously disposable (`rw_probe.connectivity`), and
`DROP SINK` in the same block — a successful sink writes real documents to a shared cluster
within seconds. Then check `rw_catalog.rw_ddl_progress` is empty: a half-created streaming
job blocks later unrelated `DROP`s with `can not drop 1 creating streaming job`.

Related: [[risingwave-onprem]], [[ecr-repo-policy-is-per-repository]].

## 2026-10-21 — a host:port sink URL cannot address an SRV cluster

op-dev's `etl-pipeline-apply` failed with
`required runtime values are missing or empty: MONGODB_HOST,MONGODB_PASSWORD MONGODB_PORT,MONGODB_USERNAME`.
They were never defined anywhere, and they **cannot be**: the secret holds
`MONGODB_CONNECTION_STRING` = `mongodb+srv://…@mongodb.bjpgt.mongodb.net`, and an SRV URI has
**no port** — DNS supplies several shard hosts at lookup. So
`mongodb://%MONGODB_USERNAME%:%MONGODB_PASSWORD%@%MONGODB_HOST%:%MONGODB_PORT%/` has nothing
valid to hold.

**The working line is commented out directly above the broken one** in both
`100-Brand/400-sink.rw` and `300-Employee/999-downstream_sinks.rw`:

    --mongodb.url = '%MONGODB_CONNECTION_STRING%',
    mongodb.url   = 'mongodb://%MONGODB_USERNAME%:%MONGODB_PASSWORD%@%MONGODB_HOST%:%MONGODB_PORT%/',

**How to apply:** when a substitution variable is undefined everywhere and nobody can say what
it should be, suspect the **form** rather than the value — and read the commented-out lines
above it, which usually record what was tried. ⚠️ Only the **sinks** use the four-part form;
everything else already uses the connection string. ⚠️ Brand's file still carries a commented
`mongodb://root:abcd@rw-mongodb:27017/` literal inside a `/* */` block — inert, but it is the
local-dev credential this repo keeps re-introducing.

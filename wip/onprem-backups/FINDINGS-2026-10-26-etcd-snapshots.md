# etcd snapshots are real on all three on-prem clusters

**Measured 2026-10-26**, cluster side and bucket side, with
`scripts/check-etcd-backups.sh dev|qa|prod`.

## Proven

One CronJob per cluster, `etcd-backup/etcd-snapshot-to-s3`, schedule `17 * * * *`,
`suspend: false`, **zero failed Jobs**, last success minutes before the check on all three.

| Cluster | Bucket (us-east-2) | Objects | Newest snapshot | Keys | Profile that can list it |
|---|---|---|---|---|---|
| op-dev | `etcd-snapshots-op-usxpress-dev` | **743** | 359,747,616 B | 13,933 | `usx-dev` |
| op-qa | `etcd-snapshots-op-usxpress-qa` | **742** | 144,379,936 B | 9,667 | `usx-qa` |
| op-prod | `etcd-snapshots-op-usxpress-prod` | **744** | 120,328,224 B | 12,214 | `ops-controller` |

**This is the property, not a proxy.** Each pod's own log shows the snapshot taken, its
byte count and key count, then the AWS CLI's own `upload:` confirmation — under
`set -euo pipefail`, so a failed `aws s3 cp` would abort before `Upload OK.` The bucket
listing then shows the object.

## ✅ Retention is 31 days, and nobody had written that down

744 objects is **31 days x 24 hours**, and the oldest key on every cluster is
**2026-09-25** — three different buckets, three counts within two of each other, one
start date. That is a lifecycle rule doing exactly what a lifecycle rule should, and it
answers the question `lastSuccessfulTime` cannot: **we can restore to any hour in the
last 31 days.**

It was previously unknown in both directions — whether snapshots expired at all, and
whether they grew without limit.

## ⚠️ op-dev's snapshot has not changed size in 31 days, to the byte

`359,747,616` on 2026-09-25 and `359,747,616` on 2026-10-26, while its revision reached
199,583,549. etcd's backend file is a high-water mark that never shrinks, so a plateau is
expected — but dev's snapshot is **3x prod's** while holding a comparable number of keys
(13,933 against 12,214). That is free pages, not data. **op-dev's etcd wants a defrag**,
and until it gets one every hourly snapshot carries ~240 MB of nothing.

Storage, for scale: roughly 268 GB on dev, 107 GB on QA, 89 GB on prod — about **464 GB
of etcd snapshots** in total, most of dev's being empty pages.

## ⛔ Not proven, and it is now the only question that matters

**No snapshot has ever been restored.** Not on dev, not on QA, not on prod. We have gone
from "we think there are backups" to "there are 744 verified objects per cluster covering
31 days", and the next step is not more measuring — it is restoring one into a throwaway
etcd and reading a key back. A backup nobody has restored is a hypothesis with a cost.

Do the drill on **dev**, which has the largest and least valuable snapshot.

## Tested and killed

* ~~"QA's etcd backups are failing"~~ — came from the 2026-09-18 sweep
  (`EtcdSnapshotJobFailing` x5) and was repeated on 2026-10-26 as a current fact. It is
  resolved. **An alert state is a reading with a timestamp, not a standing fact.**
* ~~"the destination is not in the CronJob spec"~~ — it is: `S3_BUCKET` in the container
  env. The first check grepped for `s3://` and an etcd-ish word, matched the namespace
  name, and reported that as the destination. A pattern that knows one shape finds one
  shape.

## Traps

* **`kubectl get jobs` columns moved.** Newer kubectl prints STATUS first, so positional
  `awk` printed DURATION under the heading "age": three Jobs an hour apart all read `17s`
  and looked like a single burst. Name the columns.
* **A green CronJob is not a backup.** The Job exits zero when the script runs; it says
  nothing about an object existing. Read the bucket.
* **A readable, empty bucket is a failure; an unreadable one is NOT MEASURED.** They look
  alike in a script that only counts, and they are opposite findings.
* **Each cluster needs a different AWS profile** — `usx-dev`, `usx-qa`, `ops-controller`.
  Resolve by which one can list the bucket, never by name.

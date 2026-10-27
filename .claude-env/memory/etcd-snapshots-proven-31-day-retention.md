---
name: etcd-snapshots-proven-31-day-retention
description: "MEASURED 2026-10-26: etcd snapshots run hourly at :17 on all three on-prem clusters and 742-744 objects exist in each etcd-snapshots-op-usxpress-{dev,qa,prod} bucket — 31 days x 24h, oldest key 2026-09-25. Restore has NEVER been tested."
metadata:
  type: project
---

**Proven on dev, QA and prod**, cluster side and bucket side, with
`scripts/check-etcd-backups.sh dev|qa|prod`. CronJob `etcd-backup/etcd-snapshot-to-s3`,
`17 * * * *`, `suspend: false`, zero failed Jobs.

| Cluster | Bucket (us-east-2) | Objects | Newest | Keys | Profile |
|---|---|---|---|---|---|
| op-dev | `etcd-snapshots-op-usxpress-dev` | 743 | 359,747,616 B | 13,933 | `usx-dev` |
| op-qa | `etcd-snapshots-op-usxpress-qa` | 742 | 144,379,936 B | 9,667 | `usx-qa` |
| op-prod | `etcd-snapshots-op-usxpress-prod` | 744 | 120,328,224 B | 12,214 | `ops-controller` |

**Retention is 31 days** — 744 = 31 x 24, and the oldest key on all three is 2026-09-25.
Three buckets, three counts within two of each other, one start date. So the restore
window is any hour in the last 31 days, which `lastSuccessfulTime` can never tell you.

⛔ **No snapshot has ever been restored.** That is the open question now, not whether
backups exist. Drill on dev.

⚠️ **op-dev's snapshot is byte-identical over 31 days** (`359,747,616`) and 3x prod's for
a comparable key count. etcd's backend file is a high-water mark, so that is free pages:
**op-dev wants a defrag**, and until then each hourly snapshot carries ~240MB of nothing.

**Why:** the September reading `EtcdSnapshotJobFailing` x5 on QA was quoted on 2026-10-26
as a current fact and was resolved. **An alert state is a reading with a timestamp, not a
standing fact** — see [[adjacent-step-green-signals]].

**How to apply:** run the script per cluster; it resolves the AWS profile by which one can
LIST the bucket, because each cluster needs a different one. A green CronJob is not a
backup ([[proxy-is-not-the-property]]); a readable EMPTY bucket is a failure while an
unreadable one is NOT MEASURED ([[transport-failure-not-a-verdict]]); and `kubectl get
jobs` puts STATUS first on newer versions, so positional awk reports DURATION as age
([[a-guard-can-measure-the-wrong-thing]]).

Full record: `wip/onprem-backups/FINDINGS-2026-10-26-etcd-snapshots.md`.

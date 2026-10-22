---
name: off-by-default-defeated-in-its-own-pr
description: "PR #97 built an off-by-default bootstrap hook and turned it on for dev in the same PR. The hook failed at sync wave 0 and stopped dev's pipeline applying anything. Idempotent SQL is not idempotent permissions."
metadata:
  type: feedback
---

**2026-10-15.** PR #97 added a database bootstrap hook to the RisingWave ETL chart. Its own
header says the right thing:

> OFF by default. Only an environment whose values file sets bootstrap.enabled gets it. A new
> behaviour that defaults ON is how a working environment gets broken by a merge in a repo
> where every environment shares one branch.

**And the same PR set `bootstrap.enabled: true` in `values-dev.yaml`**, reasoning that dev's
objects already existed so the first run would be a harmless no-op proving the hook.

It failed:

```
role rw_entity_app exists, leaving its password alone
database entities exists
schema employee
ERROR:  permission denied for database entities
```

**Idempotent SQL is not idempotent permissions.** `CREATE SCHEMA ... IF NOT EXISTS` is safe to
re-run only if you may create in that database. Dev's `entities` was created by hand on
2026-10-09 and the admin role (`PG_USER`) does not own it. Three of four statements were
genuinely no-ops; the fourth needed a privilege nobody had checked.

⚠️ **The blast radius was the whole pipeline, not the hook.** It is a Sync hook at
`sync-wave: "0"` and `etl-pipeline-apply` is wave 1, so a failing wave 0 means **nothing
applies on dev at all**. Fixed by #124 setting it false; dev recovered 22:36:05Z.

⚠️ **A failed hook makes the next sync a no-op** ([[failed-hook-job-makes-sync-a-noop]]), so
merging the fix was not enough. Recovery needed a forced sync by writing `.operation`:

```sh
kubectl -n argocd patch app risingwave-etl --type merge \
  -p '{"operation":{"initiatedBy":{"username":"doke"},"sync":{"syncStrategy":{"hook":{}}}}}'
```

and the proof is `startedAt` being LATER than the failed run's, not merely `Succeeded`.

**How to apply:**
- **Ship the switch off, in every file, in the PR that introduces it.** Turning it on is a
  separate, revertible change. A safety design defeated in its own PR provides nothing.
- Before claiming a run will be a no-op, ask what **privilege** each statement needs, not just
  whether the object exists.
- A hook at wave 0 gates everything behind it. Weigh a new wave-0 hook as "can stop the whole
  pipeline", never as "worst case this one thing fails".

Related: [[promotion-order-qa2-dev-qa-prod]], [[hook-job-failure-destroys-its-own-log]],
[[missing-credential-may-mean-missing-system]].

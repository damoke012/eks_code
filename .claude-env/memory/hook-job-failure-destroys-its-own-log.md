---
name: hook-job-failure-destroys-its-own-log
description: "Argo CD removes a sync-hook Job on FINAL failure, deleting the pod and its logs, so the only record is operationState.syncResult — recover the log by re-running the same digest as a plain Job under a different name"
metadata:
  type: reference
---

**2026-10-08, op-usxpress-dev.** The ETL applier's hook Job failed. Minutes later there was
no Job, no pod and no log — and `sync.status: Synced`, `health: Healthy`, because a hook is
not in the Application's tracked resource set.

**Success and never-ran look identical** from the outside: `hook-delete-policy:
BeforeHookCreation,HookSucceeded` deletes the Job on success, and Argo deletes it on final
failure too. Neither leaves anything behind.

**The one place it is recorded** is the Application's `status.operationState`:

```bash
kubectl -n argocd get applications.argoproj.io <app> -o json \
  | python3 -c 'import json,sys
op=json.load(sys.stdin)["status"]["operationState"]
print(op["phase"], op["startedAt"], op["finishedAt"])
for r in op["syncResult"]["resources"]: print(r["kind"], r["name"], r.get("hookPhase"))'
```

`Job … hook=Failed` is the proof it ran and failed. `status.resources` will not show it.

**To get the log, reproduce it — do not re-sync.** A re-sync destroys the previous attempt
too. Fetch the base Job manifest, strip the `argocd.argoproj.io/hook*` annotations, rename
it, set `backoffLimit: 0`, and apply it. Two traps:

1. **Pin the digest.** Kyverno on these clusters refuses both an unapproved registry and an
   unpinned tag at admission — `require-approved-registry` and `require-image-digest`. The
   base manifest carries the bare name `etl-pipeline` because the overlay substitutes it, so
   a naive copy is rejected. Verify the substitution landed **before** applying, or the
   failure is an admission denial that looks like a different bug.
2. **Anchor the substitution on the value, not the end of line.** `image: etl-pipeline` has a
   trailing comment, so `^\s*image:\s*etl-pipeline\s*$` silently does not match.

Related: [[failed-hook-job-makes-sync-a-noop]], [[adjacent-step-green-signals]],
[[transport-failure-not-a-verdict]].

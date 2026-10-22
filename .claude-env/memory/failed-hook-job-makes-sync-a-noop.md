---
name: failed-hook-job-makes-sync-a-noop
description: An Argo sync with a failed hook Job still present returns the OLD failure instantly without re-running; the tell is startedAt == finishedAt
metadata:
  type: feedback
---

**A failed Argo CD hook Job short-circuits the next sync.** The operation returns in the
same second it started, `syncResult` carries the *previous* Job's message — typically
`Job has reached the specified backoff limit` — and nothing is re-run. Merging the fix
changes nothing, so it reads as "my fix didn't work" when the fix was never exercised.

2026-09-11, op-usxpress-qa: hit twice in one hour while clearing the ETL pipeline. Both
times the evidence was in the timestamps, not the message:

    started =2026-09-11T12:59:36Z
    finished=2026-09-11T12:59:36Z     <- zero seconds. Nothing ran.

It clears once the failed Job is gone (`ttlSecondsAfterFinished`, `BeforeHookCreation`, or
deleting it). A sync issued after that creates a fresh Job and the fix takes effect.

A separate deadlock in the same family: a hook Job marked for deletion keeps
`argocd.argoproj.io/hook-finalizer` until the hook *completes*, so a hook that can never
complete blocks its own replacement forever. Clear `.operation` on the Application, then
drop the finalizer — only on a Job that already carries a `deletionTimestamp`.

**How to apply:** before concluding anything from a failed sync, compare
`.status.operationState.startedAt` with `.finishedAt`. Equal means the result is a replay,
not a run. See [[eso-writes-partial-secrets]], [[adjacent-step-green-signals]].

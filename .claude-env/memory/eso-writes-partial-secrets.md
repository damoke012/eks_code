---
name: eso-writes-partial-secrets
description: "ESO reports SecretSyncedError and STILL writes the keys it could resolve — the Secret looks populated, the pod dies at container creation rather than at sync, and an Argo sync-hook Job that can never start blocks every later sync silently"
metadata:
  type: feedback
---

**2026-09-08, op-usxpress-qa / `app-risingwave`.** `etl-pipeline-apply-djbp9` sat in
`CreateContainerConfigError` for **6d20h — 45,497 attempts** — and nobody noticed:

    couldn't find key POSTGRES_ENTITY_USER in Secret app-risingwave/etl-pipeline-credentials

The ExternalSecret maps **five** keys; the Secret held **three**. The
`op-usxpress-qa/risingwave/entity-postgres/{username,password}` records had never been
created in Secrets Manager — they are `iaac-risingwave-onprem` Terraform's, behind the
Octopus `TfApply` gate, and were recorded on 2026-09-02 as a *deferred* blocker. Deferred
was wrong: it had been blocking QA since 1 September.

**This is NOT [[eso-secretsynced-not-content-check]].** That one is a green sync over bad
content. Here ESO was **honest** — the condition reads `SecretSyncedError`. Three separate
things went wrong around an accurate error:

1. **ESO wrote a PARTIAL Secret anyway.** Three of five keys. `kubectl get secret` shows a
   populated object. The missing key only surfaces at **container creation**, one layer
   below where anyone was looking.
2. **Nobody watched the ExternalSecret's condition.** The object we all check is the
   Secret; the object that told the truth is the ExternalSecret.
3. **Nothing alerted for seven days**, on a cluster where alert delivery was fixed
   2026-08-24. A pod in `CreateContainerConfigError` with `RESTARTS 0` matches no rule
   keyed on restarts or CrashLoopBackOff — the count stays at zero because the container
   never starts. See [[adjacent-step-green-signals]].

**The second-order failure, which cost more.** That Job is an **Argo CD Sync hook**. A hook
that never completes means the sync never completes, so **every later change to that
Application silently does not apply**. We merged promotion PR #20 and confirmed the merge;
QA was still running the 19 August image. Identical shape to the terminal Failed Job that
held Flux's `risingwave-onprem` at `Ready=False` on prod a week earlier —
[[flux-stale-dependency-cascade]], [[gitops-has-four-stale-layers]].

**How to apply.**

1. **A Secret's existence, and even its key count, is not its completeness.** Compare
   `spec.data[*].secretKey` on the ExternalSecret against the keys actually in the Secret:
   `kubectl get es X -o jsonpath='{range .spec.data[*]}{.secretKey}{"\n"}{end}'` vs
   `kubectl get secret X -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'`.
   Keys only — never print values.
2. **Read `.status.conditions[].reason` on the ExternalSecret, not the Secret.** It says
   `SecretSyncedError` and names nothing else that will.
3. **`CreateContainerConfigError` with `RESTARTS 0` is invisible to restart-based alerting.**
   Alert on pod phase and container *waiting reason*, not on restart counts.
4. **When a promotion "lands", check whether a sync hook is wedged** before believing it:
   `kubectl -n <ns> get jobs,pods` and look at the Job's age. A merged PR is not an applied
   PR — [[proxy-is-not-the-property]] instance 7 is the same lesson for Jira.
5. **Fix order is forced**: create the records → confirm the Secret has every key by
   listing them → *then* delete the wedged Job so the controller recreates it. Deleting
   first just re-wedges it. Same ordering as
   [[policy-cannot-fix-what-stops-it-running]].

Full write-up: `wip/rw-etl-promotion/STATE.md` (2026-09-08) and
`wip/rw-etl-promotion/pr-comments/pr22-round1.md`.

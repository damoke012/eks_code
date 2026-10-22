---
name: irsa-webhook-fails-open-at-pod-creation
description: "pod-identity-webhook has failurePolicy: Ignore — a pod created while it is unreachable runs forever with NO AWS credentials, silently, and only a pod RECREATE fixes it"
metadata:
  type: project
---

op-usxpress-dev's RisingWave was storage-dead for **54 days** and every health check was green
throughout. Found 2026-09-15 by a DDL canary written to test something else entirely.

**Mechanism.** `pod-identity-webhook` (the self-hosted IRSA injector on Talos) has
`failurePolicy: Ignore`. If it cannot be reached when a pod is *created*, the pod starts with
no `AWS_ROLE_ARN`, no `AWS_WEB_IDENTITY_TOKEN_FILE`, and no projected token — and **nothing is
logged, nothing is rejected, nothing alerts**. The service account annotation is still correct,
so every `kubectl describe` looks right.

Injection happens at pod CREATION only. Container restarts do not re-run the webhook, so a pod
can carry the defect for its whole life. `risingwave-compactor-default` did: 88 days old,
6 container restarts, never any credentials.

**Blast pattern — one pod, whole system.** Only the compactor was affected. But the compactor
reads and writes Hummock SSTs, so:

- compactor log: `risingwave_object_store::object: read failed error=Timeout error: Retry
  attempts exhausted for read`, repeating every few hundred ms
- Level 0 stuck at 359 SSTs, levels 1-6 empty — compaction dead, so barriers cannot checkpoint
- compute: `wait_for_epoch ... elapsed=4645511s` — 53.8 days, exactly the compute pod's age
- every `CREATE TABLE` hung at 0.0% forever; `zz_probe_t` had been stuck since 2026-08-28

**Fix:** `kubectl -n risingwave rollout restart deployment risingwave-compactor-default`.
The new pod got the token immediately (the webhook is healthy now), `read failed` went to zero,
the stuck DDL cleared, and `CREATE TABLE pipeline_canary.ddl_probe` succeeded. ✅ 2026-09-15.

**How to apply:**
1. A timeout to S3 is not proof of a network fault. DNS resolved, TCP 443 was open, and an
   unauthenticated HTTPS GET to the bucket returned 403 in 0.12s. The pod simply had no
   identity to sign with.
2. **Check IRSA per POD, not per service account, and not from one sample.** I exec'd into the
   compactor, found no credentials, and reported "the pods have no credentials" — meta, compute
   and frontend all had them. One pod is not the population, even inside one workload.
   `kubectl -n <ns> get pods -o jsonpath` over `.spec.containers[0].env[?(@.name=="AWS_WEB_IDENTITY_TOKEN_FILE")]`
   shows every pod at once; an empty `[]` next to populated siblings is the tell.
3. **A check could have caught this**: alert on any pod whose SA carries
   `eks.amazonaws.com/role-arn` but whose spec has no `AWS_WEB_IDENTITY_TOKEN_FILE`. That is a
   cheap, cluster-wide query and it would have fired on day one instead of day 54.
4. `failurePolicy: Ignore` is the fail-open trap from [[authoring-gate-hooks]] wearing a
   different hat — here the thing that fails open is a *mutator*, so the workload starts
   without the thing it needed and nobody is told.

Related: [[adjacent-step-green-signals]], [[proxy-is-not-the-property]],
[[transport-failure-not-a-verdict]], [[onprem-alerts-not-delivered]].

---
name: pod-env-secret-resolution
description: Env from secretKeyRef resolves at POD creation, not container restart — a workload can run for months on a credential that exists nowhere else
metadata:
  type: reference
---

An env var sourced from `secretKeyRef`/`configMapKeyRef` is resolved when the **pod** is
created. A container restart inside that pod replays the ORIGINAL value; only pod
recreation re-reads the secret.

**Proven on op-usxpress-qa 2026-08-20.** `risingwave-meta-default-0` was created
2026-08-11 17:15 UTC. The Postgres password was rotated in Secrets Manager 2026-08-12
13:35 UTC. Its 238 container restarts (exit 139 / SIGSEGV, all in the first 16 hours) each
replayed the pre-rotation password and each succeeded, so nothing looked wrong for 8 days —
while every ExternalSecret, every Kubernetes Secret and Secrets Manager itself carried a
value the database had never accepted.

**Why it matters:** the failure is deferred to whatever recreates the pod — a node drain, an
eviction, an image bump — and lands on whoever is on call, disconnected from the rotation
that caused it. A restart count in the hundreds with a healthy pod is not reassurance; it is
evidence the env has not been re-read since the pod was created.

**How to apply:**
- After ANY secret rotation, recreate the pods that consume it. `kubectl rollout restart`
  creates new pods, so it is sufficient; a crash-restart is not.
- When a credential fails for one workload but "works" for another, compare pod **creation**
  times against the secret's `LastChangedDate` before assuming the secret is wrong.
- `kubectl get pod X -o jsonpath='{.status.startTime}'` is pod creation; `restartCount` is
  container restarts. They answer different questions.

See [[eso-secretsynced-not-content-check]] and [[qa-postgres-password-drift]].

⚠️ **Possible exception, 2026-09-03 — risingwave-console on op-usxpress-prod.** Idris's
automation wrote the real licence into Secrets Manager; `rw-license-key` synced; and the
console recovered **without the pod being recreated**. `kubectl get pods` showed AGE 45h
(original pod), 532 restarts at ~1 per 5 min, then 50 minutes stable. So the new value
reached the container on a *container* restart.

Not yet explained. Most likely the console mounts the secret as a **volume** (updates in
place) rather than taking it through `secretKeyRef` env. **Confirm before trusting it** —
if true, INFRA-1688's "the pod must be recreated" step is wrong for this workload, and the
rule in this note holds only for env-injected values. Do not generalise the exception until
the pod spec has been read.

---
name: dx-deploy-failure-not-clean-release
description: A failed DX deploy is never a reason to clean-release; the three real failure modes and their fixes
metadata: 
  node_type: memory
  type: feedback
  originSessionId: e3125f37-c991-4364-adf2-b40770a2d61c
  modified: 2026-08-13T22:29:09.850Z
---

When a DX deployment fails at `DX-Apply`, teams reach for **"Clean up entire project"**. That
destroys and recreates the Azure app registration, minting a new client ID and breaking every
consumer until each gets a full release.

**Why:** on 2026-08-10 three clean releases of `orders-api` produced four client IDs and left 15
services unable to authenticate for 16+ hours. Every real failure mode has a fix that leaves
identity alone.

**How to apply:** work the three known modes before considering anything drastic.

1. `external-secrets.io/v1beta1` / `no matches for kind` → the release pins old `mage` /
   `tf-apps`. Fix: **empty commit → new release**. (Rohit Saini, 2026-08-13; fixed
   `trailer-validation-alert-api` and `usx-orders-auto-booking-handler`.)
2. `Error: <resource> already exists` → Terraform state drift. Check `creationTimestamp`; if the
   objects are minutes old they're orphans from a failed apply. Delete them, re-run. **Do not
   restart pods in between** — anything referenced by `envFrom` leaves running pods unable to
   restart.
3. `context deadline exceeded` on `helm_release.api` + `CreateContainerConfigError` → deadlock.
   Helm waits for a rollout that can't start. Restore the missing object from **Terraform state in
   S3** while the task is still waiting, and it completes itself.

**Prevention:** projects that don't deploy regularly fail exactly when needed. `usx-missions-api`
had not deployed to prod since May 2025 — that gap is why its state and the cluster diverged.

Runbook: `docs/runbooks/SOP-dx-deploy-failure-recovery.md`.
Related: [[octopus-green-but-no-apply]], [[dx-entra-app-recreation]], [[prod-standup]].

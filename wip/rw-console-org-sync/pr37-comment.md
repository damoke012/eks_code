#36 is live on QA as of today — but not because it merged. It merged four hours ago and
never applied. Worth writing up properly, because the cause is not in your manifest and
it will bite the dev and prod promotions next.

## What was actually happening

Flux was failing its server-side-apply dry-run on every reconcile:

```
Deployment/risingwave/risingwave-console dry-run failed (Invalid):
  Deployment.apps "risingwave-console" is invalid:
  spec.strategy.rollingUpdate: Forbidden: may not be specified when strategy `type` is 'Recreate'
```

The live Deployment still carried the `rollingUpdate` block Kubernetes had defaulted onto
it back when it was a RollingUpdate:

```json
{"rollingUpdate":{"maxSurge":"25%","maxUnavailable":"25%"},"type":"RollingUpdate"}
```

Server-side apply does not drop a field just because the manifest stops declaring it. So
`type: Recreate` and a leftover `rollingUpdate` coexisted on the live object, which the API
server forbids. **Your manifest was correct** — it could not land on an object that already
existed. On a fresh Deployment it would have applied first time.

Two things made it expensive, and neither is obvious:

- **A dry-run failure fails the whole Kustomization.** `risingwave-onprem` and
  `risingwave-operator` were both frozen — nothing in either could apply, not just the
  console.
- **Nothing reported it.** op-usxpress-qa has no Alertmanager and no Flux PrometheusRule,
  so there was no alert to miss. It was found by looking.

## The fix, already applied to QA

One-time state repair — the field is removed from the live object, nothing to change in Git:

```bash
kubectl -n risingwave patch deploy risingwave-console --type=json \
  -p '[{"op":"remove","path":"/spec/strategy/rollingUpdate"},
       {"op":"replace","path":"/spec/strategy/type","value":"Recreate"}]'
```

Flux then reconciled cleanly. Verified at the pod, not at the Kustomization status:
`risingwave-console-5cb7cfb7c6-dvqbz`, age 118s, init containers now
`fix-data-dir init-db sync-orgs render-config gen-dex-cert`. Your org sync is running.

## So: close this PR

`rollingUpdate: null` is a legitimate SSA workaround, but it is fixing the manifest side of
a problem that lived in the live object, and QA is already fixed without it. It also has two
red checks (`Terraform Validate`, `dpl`) that were never explained, and whether
`kustomize build` preserves a null-valued field was never actually tested — the test run
reported `kustomize not installed or build failed`, which proves nothing either way.

## What is worth doing instead

**1. Dev needs the same change #36 made to QA.** Dev's console is owned by the same
`risingwave-onprem` Kustomization, Ready at `main@62e56b3d`, and still declares
`RollingUpdate`. Round 2 established why `Recreate` is required — RWO PVC, `replicas: 1`,
so a rolling update deadlocks on multi-attach. Dev has that same shape today.

**When you do, dev will hit this identical wall** — its live object has the `rollingUpdate`
block right now. Run the patch above against dev either just before or just after the merge;
otherwise the dev Kustomization freezes the same way and everything else in it stops with it.

**2. The prod promotion needs the same care.** If prod's console Deployment already exists,
the promotion PR hits this too — and on this repo a merge to `main` is a production deploy
with no gate, so it would fail unattended, silently, and freeze `risingwave-onprem` on prod.
Check before raising it, and if the object exists, plan the patch as part of the change.

**3. Unrelated, found while patching.** The console's `fix-data-dir` init container runs as
root:

```
Warning: would violate PodSecurity "restricted:latest": runAsNonRoot != true
(container "fix-data-dir" must not set securityContext.runAsNonRoot=false), runAsUser=0
```

Warn-only today because the `risingwave` namespace is not enforcing. The day it enforces,
the console stops scheduling — QA and prod both. Worth fixing while you are in this file.

## On our side

The review missed this across both rounds. We asked *why* `Recreate` and satisfied ourselves
the reason was sound; we never asked whether it could apply to the object that already
exists. That is now a standing checklist item, and we have a weekly check that reports any
Flux Kustomization stuck not-Ready with its error message, until a real alert path exists.

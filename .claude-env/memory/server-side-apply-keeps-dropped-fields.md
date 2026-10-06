---
name: server-side-apply-keeps-dropped-fields
description: Server-side apply keeps a field the manifest stops mentioning, so a mutually-exclusive change is rejected forever on a live object while valid on a fresh one; the dry-run failure freezes the WHOLE Flux Kustomization, silently
metadata:
  type: project
---

2026-09-15, op-usxpress-qa, ns `risingwave`. `iaac-risingwave-onprem` #36 switched the console
Deployment to `strategy: Recreate`. Flux's server-side-apply **dry-run** rejected it on every
reconcile for ~4 hours:

`spec.strategy.rollingUpdate: Forbidden: may not be specified when strategy type is 'Recreate'`

The live object still carried the `rollingUpdate` block Kubernetes had defaulted onto it.
**SSA does not drop a field just because the manifest stopped declaring it.** The manifest was
correct — it simply could not land on an object that already existed. A fresh Deployment
applies first time, so a new environment never reproduces it.

Three things that made it expensive:

- **A dry-run failure fails the whole Kustomization.** `risingwave-onprem` and
  `risingwave-operator` both froze; the other 40 QA Kustomizations were fine. The blast radius
  is the Kustomization, not the resource.
- **Nothing alerted.** Found by Doke looking at QA. Now ALERTS-TO-BUILD C6, high severity.
- **Two review rounds missed it** — both asked whether `Recreate` was *correct*, neither asked
  whether it could *apply*. Now a checklist item in `pr-review-rw`.

**Why:** "merged" and "applied" are different states, and everything in between reports Ready.
The pre-merge pod ran for four hours after approval.

**How to apply:** repair by removing the field from the live object — a one-time state repair,
**not** something to encode in Git, because the desired state is already there and what you are
removing is a field Git never declared. `kubectl patch --type=json -p
'[{"op":"remove","path":"/spec/strategy/rollingUpdate"},{"op":"replace","path":"/spec/strategy/type","value":"Recreate"}]'`.
Avoid `spec.force: true` on the Kustomization — a permanent broad grant to recreate on any
apply conflict, to fix one historical field. Then verify at the **pod**: its age in seconds and
a field only the new template has. Note a strategy patch alone does **not** restart anything —
the template is unchanged, so no new ReplicaSet.

Related: [[gitops-has-four-stale-layers]], [[adjacent-step-green-signals]],
[[octopus-green-but-no-apply]], [[kustomization-enumerates-resources]].


**2026-09-15 addition — measured, not inferred:** op-usxpress-prod's `risingwave-console`
carries the identical stale `rollingUpdate` block, so the prod promotion of `Recreate` will
freeze `risingwave-onprem` on prod. That repo has no gate between merge and prod and no
Alertmanager, so it would fail unattended. Order matters: clear the live field FIRST (a
strategy patch alone restarts nothing), then merge. I had earlier said prod would apply clean
because its manifests did not exist — wrong, and it came from reading a ticket note instead of
the cluster.

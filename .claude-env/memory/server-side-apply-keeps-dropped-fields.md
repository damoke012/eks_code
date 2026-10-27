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

## ⚠️ 2026-10-27 — the recorded ORDER is wrong when the cluster is pinned behind

The 2026-09-15 note above says *"clear the live field FIRST, then merge."* On op-usxpress-prod
that is **backwards**, and following it cost two repairs and an hour.

Measured, with timestamps:

| | |
|---|---|
| 17:5x | patched the live Deployment: `{"type":"Recreate"}`, no `rollingUpdate`. The 14-day deadlocked rollout completed, console `2/2 Running` |
| 18:02:49 | `kustomize-controller  Apply` + `kube-controller-manager  Update`, same second |
| after | live object back to `{"rollingUpdate":{...},"type":"RollingUpdate"}` |

**Flux reconciled the OLD pinned manifest (`v0.11.3`), which declares no `strategy` at all,
so the API server re-defaulted `RollingUpdate` and the repair was gone within the interval.**
`metadata.managedFields` names both writers and is how to see this; the console pod is
untouched throughout, so nothing looks wrong.

**The correct order, when the source is a pinned tag:**

1. Merge the fix and cut the tag.
2. **Move the cluster's pin to that tag** (for us: `iaac-talos-flux-cluster`,
   `clusters/op-usxpress-<env>/flux-system/infra.yaml` — see
   [[cluster-can-be-behind-its-own-repo]]).
3. **Only then** clear the live field. Now the manifest declares `Recreate` too, the next
   apply agrees with the live object, and the repair holds.

Done in that order it worked first time: patched at ~18:28, `v0.13.3 ready=True` at 18:34:59.

**Why the September order was right THEN and wrong NOW:** in September the RisingWave sources
tracked `branch: main`, so "merge" and "the cluster has it" were the same moment and clearing
first avoided a window of failure. Since the tag pinning landed they are days apart, and
clearing first just hands the old manifest a chance to undo it. **A procedure that encodes an
ordering assumes a delivery model; when the model changes the ordering can invert.**

**How to apply:** before a live-object repair, read what the cluster is actually applying —
`kubectl -n flux-system get kustomization <name> -o jsonpath='{.status.lastAppliedRevision}'`.
If that revision does not contain the fix, repair later, not sooner.

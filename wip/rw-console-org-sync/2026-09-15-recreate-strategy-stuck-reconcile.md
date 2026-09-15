# QA console: `strategy: Recreate` could not apply to a live Deployment (2026-09-15)

PR #36 merged, was never applied for ~4 hours, and nothing said so. Found because Doke
looked at QA, not because anything alerted.

## What happened

`iaac-risingwave-onprem` #36 changed the console Deployment to `strategy: Recreate`.
Flux's server-side-apply **dry-run** rejected it on every reconcile:

```
Detecting drift for revision main@sha1:62e56b3dd6ebdd42255b3f14a6340b2071fbc82f
Deployment/risingwave/risingwave-console dry-run failed (Invalid):
  Deployment.apps "risingwave-console" is invalid:
  spec.strategy.rollingUpdate: Forbidden: may not be specified when strategy `type` is 'Recreate'
```

The live object still carried the field Kubernetes had defaulted onto it years earlier:

```json
{"rollingUpdate":{"maxSurge":"25%","maxUnavailable":"25%"},"type":"RollingUpdate"}
```

Server-side apply does not drop a field just because the manifest stopped mentioning it.
The manifest was correct; it could not land on an object that already existed.

## The fix

One-time state repair on op-usxpress-qa — not configuration, so nothing to encode in Git.
The desired state was already in Git; what was removed is a field Git never declared.

```bash
kubectl --kubeconfig /home/doke/.kube/op-usxpress-qa.yaml -n risingwave \
  patch deploy risingwave-console --type=json \
  -p '[{"op":"remove","path":"/spec/strategy/rollingUpdate"},
       {"op":"replace","path":"/spec/strategy/type","value":"Recreate"}]'
```

Flux then reconciled on its own interval and the new template landed.

## Proven (op-usxpress-qa, ns `risingwave`, 2026-09-15)

- Blast radius was **two** Kustomizations — `risingwave-onprem` and `risingwave-operator`,
  both at `main@62e56b3d`. The other 40 QA Kustomizations were Ready at `op-qa@fc6f7e20`
  throughout. A dry-run failure fails the **whole** Kustomization, not just the bad resource.
- Before: pod `risingwave-console-5d7f777c5-td242`, age 3h48m, init containers
  `fix-data-dir init-db render-config gen-dex-cert` — **no `sync-orgs`**, i.e. none of #36.
- After: `risingwave-console-5cb7cfb7c6-dvqbz`, age 118s, init containers
  `fix-data-dir init-db sync-orgs render-config gen-dex-cert`, `strategy.type=Recreate`,
  both RisingWave Kustomizations Ready at `main@62e56b3d`.
- **Only pre-existing Deployments can hit this.** A freshly created object has no stale
  field, so prod's console (no `manifests/op-usxpress-prod/` yet, INFRA-1674) will apply
  clean first time.

## Tested and killed

- **"Idris broke QA."** Nothing regressed. #36 never applied at all — QA was running exactly
  what it ran before the merge. The failure mode is Kubernetes SSA, not his manifest.
- **"The patch will recreate the console pod."** It did not. A `strategy` change does not
  alter the pod template, so no new ReplicaSet. The restart came later, when Flux applied
  the new template. Claiming downtime from the patch was wrong.
- **"#37 (`rollingUpdate: null`) is the fix."** It addresses the manifest side of a problem
  that lived in the live object. Once the field is gone, plain `type: Recreate` applies
  cleanly and the null is redundant. Recommend closing #37.
- **`flux reconcile kustomization risingwave`** — no such Kustomization on QA. Dev and QA
  have **different Kustomization sets** for RisingWave (QA: `risingwave-onprem`,
  `risingwave-operator`; dev: `risingwave` at `main@035f3d4d`, `risingwave-onprem`,
  `risingwave-routes`). Never assume the name carries across clusters.

## Traps

- **A Kustomization can sit not-Ready for hours in silence.** There is no alert for this on
  any cluster. See ALERTS-TO-BUILD C6.
- **`Applied revision: X` is a claim about the apply, not about the pod.** Verified here by
  the init-container list and a pod age in seconds, not by `Ready`.
- **Dev is unresolved and was deliberately left alone.** Dev's console still reports
  `type: RollingUpdate`, but dev's `risingwave-onprem` is Ready at the same
  `main@62e56b3d` — so dev is *not* stuck. Either the dev overlay does not carry #36's
  change, or dev's console is owned by the `risingwave` Kustomization tracking a different
  revision (`main@035f3d4d`). Nothing is broken on dev; this is a config question for Idris.
  Discriminate with:
  `kubectl --kubeconfig /home/doke/.kube/op-usxpress-dev-fresh.yaml -n risingwave get deploy risingwave-console -o jsonpath='{.metadata.labels}{"\n"}'`
- **Never resolved:** whether `kustomize build` strips `rollingUpdate: null`. The test never
  ran (`kustomize not installed or build failed`) and that must not be read as evidence
  either way. It stopped mattering here, but it will matter the next time a null is used
  as an SSA workaround. `kubectl kustomize` has it built in.

## Two open items this surfaced, unrelated to the reconcile

- **Console init container runs as root.** The patch printed
  `would violate PodSecurity "restricted:latest": runAsNonRoot != true (container
  "fix-data-dir" must not set securityContext.runAsNonRoot=false), runAsUser=0`.
  Warn-only today because `risingwave` is not enforcing. The day it enforces, the console
  stops scheduling — on QA and prod both. Idris's area.
- **The console application image is a floating tag**, `risingwavelabs/risingwave-console:v0.7.4`.
  This is *not* a miss in #36 — the digest that round 2 verified was for the `postgres:17`
  init image (advisory 5). The app image was never in scope. Digest pinning is the on-prem
  posture ([[ecr-shared-registry-posture]]), so it is worth raising separately, as its own ask.

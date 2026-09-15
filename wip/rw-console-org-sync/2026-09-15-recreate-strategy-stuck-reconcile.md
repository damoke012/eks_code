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
- **Only pre-existing Deployments can hit this.** A freshly created object has no stale field.
  ~~So prod's console (no `manifests/op-usxpress-prod/` yet, INFRA-1674) will apply clean first
  time.~~ **WRONG, corrected 2026-09-15 by measuring instead of inferring.** op-usxpress-prod
  *already runs* `deploy/risingwave-console` and its live strategy is
  `{"rollingUpdate":{"maxSurge":"25%","maxUnavailable":"25%"},"type":"RollingUpdate"}` —
  identical to QA before the repair. INFRA-1674 is about the *platform* manifests path; the
  console has had `manifests/op-usxpress-prod/risingwave-console.yaml` since #36 round 1.
  **Prod will hit this wall, and on this repo a merge to `main` is a production deploy with no
  gate — so it would fail unattended and freeze `risingwave-onprem` on prod.**

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

## Why nobody was told — checked, 2026-09-15

Two independent gaps, either one sufficient:

- **op-usxpress-qa has no Alertmanager.** `kubectl get alertmanagers.monitoring.coreos.com -A`
  → `No resources found`. Every rule on that cluster fires into nothing. This matches
  [[onprem-alerts-not-delivered]], previously recorded for dev; QA is now confirmed the same.
- **No Flux rule exists to fire.** All 45 PrometheusRules on QA listed; none covers
  `gotk_reconcile_condition`. The custom ones are cilium-node-divergence, control-plane-memory,
  dns-health, etcd-backup-staleness, etcd-cluster-health, irsa-health, istio-cert-chain,
  platform-health, rook-ceph-health. `prometheus-stack-kube-prom-alertmanager.rules` is a rule
  *about* Alertmanager, not an instance of one.

Correcting an assumption made an hour earlier in this investigation: I expected the alert had
fired and reached nobody, on the strength of the 2026-08-24 "Flux rules fixed on dev+QA" note.
Wrong on QA — there is no Flux rule there to fix. Do not reason from that note without listing.

**Built instead:** `scripts/flux-kustomization-health.sh --cluster op-qa`, wired into
`weekly-maintenance.sh` section 9 alongside the existing revision-drift check. It reports the
Ready condition message, which for this failure names the resource and the exact forbidden
field. Its self-test (`flux-kustomization-health.test.sh`, 8 cases) exists because the first
version printed *"all 4 Kustomizations Ready"* from a SyntaxError in its own parser — the
[[prod-incident-instrument-check]] trap, caught by testing the instrument rather than shipping it.

## Prod: the same trap, armed, on a repo with no gate (2026-09-15)

```
op-usxpress-prod  ns risingwave  deploy/risingwave-console
{"rollingUpdate":{"maxSurge":"25%","maxUnavailable":"25%"},"type":"RollingUpdate"}
```

Byte-identical to QA before the repair. The prod promotion PR carries `strategy: Recreate`,
so on merge Flux's dry-run fails, `risingwave-onprem` freezes on **prod**, and every resource
in it stops applying. No Octopus release, no approval environment, no promotion gate — a merge
to `main` here IS the deploy. And no Alertmanager on prod either, so the only signal would be
someone noticing, exactly as on QA.

**Sequence that avoids it — the patch first, the merge second:**

1. Remove the stale field from the live prod object. **This is non-disruptive on its own** —
   proven on QA today: a `strategy` change does not alter the pod template, so no new
   ReplicaSet and no restart. This is a PRODUCTION MUTATION and is not run from this repo
   (standing rule 1); it is drafted here for whoever runs it under the normal change process.

   ```bash
   kubectl --kubeconfig /home/doke/.kube/op-usxpress-prod.yaml -n risingwave \
     patch deploy risingwave-console --type=json \
     -p '[{"op":"remove","path":"/spec/strategy/rollingUpdate"},
          {"op":"replace","path":"/spec/strategy/type","value":"Recreate"}]'
   ```

2. Confirm `{"type":"Recreate"}` and that the pod did **not** restart.
3. Then merge the promotion PR. The new template lands, the console restarts once — which
   `Recreate` implies anyway and which the promotion was always going to cause.

Doing it the other way round — merge first, repair after — means a prod freeze of unknown
duration, because nothing will report it.

**Still unmeasured on prod:** whether its console has the RWO PVC and `replicas: 1` that made
`Recreate` necessary on QA. If it does not, the promotion's premise is worth re-checking for
prod specifically rather than assumed from QA. One sample is not a population.

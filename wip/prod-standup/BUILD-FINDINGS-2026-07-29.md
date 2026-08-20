# op-usxpress-prod greenfield build — findings register (2026-07-29)

Every defect found during the first real from-scratch build of `op-usxpress-prod`
(release `.1.223`), with root cause, blast radius, and where the fix lives.

**The through-line:** all of these live on code paths that ONLY execute on a
greenfield build. dev and QA were built forward and never from scratch, so none
of them had ever run. Expect the same class of thing on the next rebuild — this
register exists so the next one is shorter.

Severity key: **S1** silent failure (looks healthy, does nothing) · **S2** hard
blocker (visible, stops the build) · **S3** correctness/hygiene (works, but wrong)

---

## F1 — istio-cni installed before ztunnel → cluster-wide sandbox blackout · S2

**Symptom.** For ~22 minutes every new pod on every node failed to get a network
sandbox:

```
plugin type="istio-cni" ... cmdAdd failed to contact node Istio CNI agent:
unable to push CNI event (status code 500): no ztunnel connection
```

~84 retries per pod. kyverno, keda, argocd and istio-ingress all blew their Helm
timeouts as collateral.

**Root cause.** `infra.yaml` ordered `istio-istiod → istio-cni → istio-ztunnel`.
That matches the order Istio's docs list for ambient — but the docs describe an
interactive install where you run the next command immediately. Under Flux with
`wait: true`, `istio-cni` must go **fully Ready** before `istio-ztunnel` is even
applied, which deliberately parks the cluster in the one state that breaks it:
CNI chained into every node with no ztunnel to answer it.

`keda` and `kyverno` have no `dependsOn` at all, so they install concurrently
with the istio chain and land squarely in that window.

**Why it looked transient.** It self-heals the moment ztunnel lands. The lasting
damage is the Helm releases that timed out during the window (see F4).

**Fix.** Swap the dependency: `istio-ztunnel dependsOn istio-istiod`, `istio-cni
dependsOn istio-ztunnel`. Safe in both directions — with no istio-cni installed,
ztunnel's own DaemonSet pods get normal Cilium networking and start clean; they
simply have no pods enrolled until CNI arrives, which is the correct steady
state.

**Where.** `iaac-talos-flux-cluster` @ `master` — **PR #30, merged.**
Applied to `clusters/op-usxpress-prod`, `clusters/op-usxpress-qa`,
`clusters/bm-dev`. `clusters/dpl` has the same ordering but is not ours — flagged
to its owners. `clusters/dpl2` is unaffected (no ztunnel Kustomization, so not
running ambient).

> **Repo topology gotcha:** dev in the *cluster* repo is `clusters/bm-dev/`, not
> `op-usxpress-dev`. Cluster repo = directory-per-env on `master`; platform repo
> = branch-per-env (`op-dev`/`op-qa`/`op-prod`). Easy to search the wrong one.

---

## F2 — istio-csr wrote `istio-ca-root-cert` to one namespace only · S2

**Symptom.** All 10 `istio-ingressgateway` pods stuck `ContainerCreating`:

```
MountVolume.SetUp failed for volume "istiod-ca-cert":
configmap "istio-ca-root-cert" not found
```

**Root cause.** Not RBAC — istio-csr was explicitly configured to write only into
`istio-system`:

```yaml
controller:
  configmapNamespaceSelector: "name=istio-system"
```

**Why prod exposed it first.** Ambient-mode namespaces (`keda`, `kyverno` —
`istio.io/dataplane-mode=ambient`) don't need the root-cert ConfigMap. Sidecar
namespaces do. `istio-ingress` carries `istio.io/rev=default`, so it is the first
namespace in the fleet ever to require it.

**Blast radius.** The selector is byte-identical on **every branch**, including
`dpl` and `dpl2`. It is very likely wrong fleet-wide and simply never surfaced.
**Unverified on QA** — the QA context was missing from the kubeconfig at the time
(see `wsl-kubeconfig-churn`). Verify with:

```bash
kubectl --context <qa> get cm -A | grep istio-ca-root-cert
```

**Fix.** `configmapNamespaceSelector: ""` — the chart default, meaning all
namespaces. ConfigMap appeared in all 21 namespaces within seconds.

**Where.** `iaac-talos-flux-platform` @ `op-prod`,
`infrastructure/istio-csr/values.yaml` — **PR #85, merged.**

### F2a — `valuesFrom` ConfigMap edits do not trigger a Helm upgrade · S1

istio-csr's values live in a `istio-csr-values` ConfigMap consumed via
`valuesFrom`. Reconciling the *Kustomization* updates that ConfigMap but the
HelmRelease keeps running old values until its next interval — so a values-only
fix looks like it did nothing for up to 10 minutes.

```bash
flux reconcile hr <name> -n <ns> --force   # required after any valuesFrom edit
```

Reloader is already in the stack; pointing it at these values ConfigMaps would
close the gap permanently. **Not yet done.**

---

## F3 — `pool=` node labels applied to the system pool only · S2

**Symptom.** `argocd-redis-secret-init` (nodeSelector `pool=platform`) could not
schedule, which failed Argo CD's Helm pre-install hook:

```
0/13 nodes are available: 10 node(s) didn't match Pod's node affinity/selector,
                           3 node(s) had untolerated taint {control-plane}
```

10 + 3 = 13 — *every* node rejected, including the three named
`talos-wk-op-prod-platform-*`.

**Root cause — NOT the Terraform.** `local.worker_pool_metadata`
(`deploy/terraform/main.tf:53`) flattens `sort(keys(pools))` × `count`, producing
exactly one entry per worker, index-aligned with `worker_vm_names`. Sorted keys
give `application`(5) → 0–4, `platform`(3) → 5–7, `system`(2) → 8–9, and the two
labelled nodes are exactly system-1/2. **The alignment is correct.**

The gap is the **input**: prod's `TF_VAR_worker_pools` JSON only carries a
`labels` key on the `system` entry.

**Second-order.** `nodeTaints` (`modules/talos/main.tf:213`) reads the same
struct, so **prod's pool taints are missing too** — nothing currently keeps
general workloads off the platform and application pools. This has no visible
symptom, which makes it worse than the labels.

**Status.** 🔧 **Labels applied by hand** (`kubectl label node ... pool=…`) to
unblock the build. **A rebuild loses them.** Source fix =
`fix-worker-pool-metadata.py`.

**Same shape as** the empty `irsa_oidc_bucket_name`: a hand-built Octopus
variable set missing fields QA has. Third such drift — see F7.

---

## F4 — a blown Helm timeout escalates into an unrecoverable release · S1

**Symptom.** kyverno reached a state Flux cannot exit:

```
Could not determine release state: unable to determine state for release
with status 'uninstalling'
```

Helm history showed `REVISION 1 · uninstalling · Deletion in progress (or
silently failed)`. Flux retries forever without progressing.

**Root cause.** The HelmReleases set no `install.remediation.retries`. When the
F1 blackout pushed an install past its timeout, helm-controller began a
rollback-uninstall; that uninstall also hung (kyverno's pre-delete hook), leaving
a non-terminal Helm state with no automatic path out.

**Three releases wedged this way in one build** — kyverno, argocd,
istio-ingressgateway. Each needed a human:

```bash
flux suspend hr <name> -n <ns>
helm -n <ns> uninstall <name> --no-hooks --timeout 5m
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations | grep -i <name>
flux resume hr <name> -n <ns>
```

> ⚠️ For kyverno specifically: **confirm the webhooks are gone before resuming.**
> Reinstalling underneath live `failurePolicy: Fail` webhooks with no running
> kyverno pods takes down cluster-wide admission.

**Fix.** `spec.install.remediation.retries: 3` (+ `upgrade.remediation`) so a
timeout retries instead of converting into an uninstall. Script:
`add-helm-remediation.py`.

**Related — cold-cluster timeouts.** The 5m health timeouts are tuned for a warm
cluster. On a greenfield build with no image cache they fire routinely and make a
healthy cluster read as broken for the first ~20 minutes. Distinguish
"`InProgress` but pods Running" (slow, self-heals) from "`Failed`/`uninstalling`"
(wedged, needs a human).

---

## F5 — op-dev, op-qa and op-prod all run `dpl2`'s mesh identity · S3

Six literals on `op-prod`:

| file | value |
|---|---|
| `istio/istiod/values.yaml:10` | `meshID: dpl2.mesh.usxpress` |
| `istio/istiod/values.yaml:11` | `cluster: dpl2.talos.mesh.usxpress` |
| `istio/istiod/values.yaml:30` | `trustDomain: dpl2.mesh.usxpress` |
| `istio-csr/values.yaml:11` | `trustDomain: dpl2.mesh.usxpress` |
| `cert-manager-issuers/issuer.yaml:29` | `- dpl2.mesh.usxpress` |
| `cilium-lb/resources.yaml:26` | `name: dpl2-lb-pool` |

**The convention is per-cluster** — the `dpl` branch uses `dpl.mesh.usxpress`
throughout. The `op-*` branches were forked from `dpl2` and never renamed.
`fix-op-prod-literals.sh` missed these because it hunted account IDs and cluster
names, not mesh domains.

**Not an active security hole.** Each cluster runs its own root CA (the
`create-istio-root-ca` job), so a workload cert from op-dev is not trusted by
op-prod. There is no impersonation path today.

**What it does break.** Multi-cluster federation, mesh-wide telemetry, and any
AuthorizationPolicy matching on principal — which would silently match the wrong
intent if these clusters are ever joined.

**Status.** 📋 **Team decision, deliberately not fixed unilaterally.** Changing a
trust domain rotates every workload identity in the mesh. **Prod is the cheap
window** — it carries no traffic today; after go-live this is disruptive.

---

## F6 — Argo CD credential is real, but is not a Terraform resource · S1 (by design)

`op-usxpress-<env>/platform/argocd` is only ever **read**, by the
`argocd-admin-credentials` ExternalSecret. Terraform never creates it. Two
consequences:

- nothing seeds it → without `seed-argocd-admin.py`, Argo CD comes up with a
  **green ExternalSecret and an unusable login**
- `terraform destroy` never deletes it → it **survives** teardown→rebuild, so
  this is once per cluster, not once per build

Verified content-level on 2026-07-29 — `argocd-secret.admin.password` starts
`$2b$` (real bcrypt, not a placeholder). This is the
`eso-secretsynced-not-content-check` trap, checked properly.

⚠️ The password was rotated and captured, but also passed through terminal
scrollback and an assistant transcript. **Rotate once more before go-live.**

---

## F7 — three prod-vs-QA drifts, all in the hand-built Octopus variable set · S2

1. `irsa_oidc_bucket_name` empty (caught pre-deploy by `--diff-qa`)
2. `worker_pools` missing `labels` on platform/application (F3)
3. `worker_pools` missing `taints` on platform/application (F3, no symptom)

All three were invisible until build time, and all three live in Octopus rather
than in code — so no amount of repo review would have surfaced them.

📋 **Action: diff prod's ENTIRE variable set against QA's, field by field.** Worth
more than any further individual fix. `add-prod-vars.py --diff-qa` covers
presence; it does **not** compare *values* inside JSON-valued variables, which is
exactly where F3 hid.

---

## Carried forward from the `.1.223` apply (still open)

| # | item | status |
|---|---|---|
| C1 | `wait_for_cluster` TCP-probes instead of polling `/healthz` — k8s provider hits the apiserver mid-restart | 🔧 `fix-wait-for-cluster.md` |
| C2 | `Out-File -NoNewline` on a PowerShell string array — same bug that flattened the kubeconfig still latent in the stuck-namespace block | 🔧 `fix-outfile-array-bug.md` |
| C3 | git-credentials secret automation (`ca5479f`) never exercised by a deploy | ⏳ next redeploy proves it, and swaps the personal PAT for Octopus's token |

---

## Acceptance

**INFRA-1589 is done when a `terraform destroy` → rebuild completes with zero
manual steps.** Not before. Every item above was found by actually running the
greenfield path once; the rebuild is what proves the fixes.

Expected remaining manual step after all fixes land: **none.**
`seed-argocd-admin.py` survives destroy and does not need re-running.

---
name: flux-stale-dependency-cascade
description: "A Flux Kustomization's 'dependency X is not ready' is the reason from its LAST FAILED ATTEMPT — X is often Ready=True right now; compare revisions, not messages"
metadata:
  type: project
---

On 2026-08-24, twelve Kustomizations on `op-usxpress-qa` sat stuck at revision `254b6c44`
while the healthy ones had advanced to `81cbcfc3`. Every one blamed a dependency that was
`Ready=True` at that moment — `istio-csr` blamed `cert-manager-issuers`, `argocd-apps` blamed
`app-namespaces`, `velero` blamed `external-secrets-config`, `rook-ceph-cluster` blamed
`rook-ceph-operator`. `grafana` blamed `prometheus` on one poll and `istio-ingress` on the
next, while `prometheus` reported `Ready=True, Healthy=True, health check passed in 72ms`.

**Why:** the message is the reason recorded at the last failed attempt, still displayed while
the Kustomization waits out its retry interval. QA's mesh chain is six deep
(`istio-csr → istio-base → istio-istiod → {ztunnel, ingress, istiod-health} → istio-cni`, with
`grafana` and `risingwave-routes` hanging off `ingress`), so one transient failure at the root
freezes the mesh and everything downstream — each level retrying only on its own timer.

Read at face value the messages send you to debug a healthy component. **The tell is the
REVISION column:** a stuck Kustomization sits one revision behind while the dependency it
names has already moved on.

**How to apply:** run `scripts/flux-revision-drift.sh --cluster op-dev|op-qa|op-prod`. It
compares each `lastAppliedRevision` against the source's served revision, flags any
Kustomization blaming a dependency that is Ready=True AND current, counts `<never applied>`
separately from `behind`, and `--print-fix` emits reconcile commands in dependsOn order
(printed, never run, for op-prod). Weekly-maintenance section 9. Do NOT trust
`flux get kustomizations` messages — compare REVISIONS. To clear it, reconcile from the
ROOT of the chain in dependency order; all twelve applied immediately and
`flux get kustomizations | grep -v True` came back empty.

A merged PR plus a successful `reconcile source git` proves nothing about what is applied.
This is [[adjacent-step-green-signals]] with a *specific and confident* wrong reason attached.
`argocd-apps` was among the twelve — QA's app delivery path, frozen while reporting a healthy
dependency as the blocker. See wip/onprem-argocd/FINDINGS-2026-08-24-argocd-url-and-route.md

## It happened TWICE on 2026-08-24, on both clusters, with different roots

op-qa: twelve stuck, root `istio-csr`, cleared by reconciling the chain in order.
op-dev: after the argocd RBAC merge, 25 behind → 8 → **4** on its own, leaving one real
root, `istio-ingress`, blaming `istio-cni` which was Ready and current. Three reconciles
(`istio-ingress`, `grafana`, `risingwave-routes`) cleared it.

**This is a property of the dependency graph, not an incident.** Any source change can leave
part of the istio chain stuck, on either cluster, and the delivery path sits behind it.

**Propagation IS drift — do not read the check immediately after a source change.** Use
`--settle 90`. Right after the reconcile op-dev showed 25 behind, all legitimate. The two
states are distinguishable in the message:

| message | meaning |
|---|---|
| `revision is not up to date` | Flux WAITING for a dependency to reach the new revision — normal |
| `is not ready`, naming an already-current dependency | the stale-message freeze |

Reading the unsettled output by hand, I picked `istio-base`/`istio-csr` as the root and was
wrong — those cleared themselves during the 90s. The settled output named the real root.
Trust `--settle`, not a first glance at a moving system.


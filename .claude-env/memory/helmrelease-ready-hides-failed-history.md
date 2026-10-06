---
name: helmrelease-ready-hides-failed-history
description: "A HelmRelease's Ready condition and its Helm history disagree; QA's Grafana was Stalled/RetriesExceeded for 66 days while the pod ran 3/3 — GitOps silently a no-op, caused by a 5m default timeout plus remediateLastFailure defaulting false for install and true for upgrade."
metadata: 
  node_type: memory
  type: project
  originSessionId: 47b0e9a0-2e5c-4874-83f1-06d3268ab121
  modified: 2026-09-18T17:58:23.373Z
---

**2026-09-18, op-usxpress-qa.** `grafana/grafana` had `Stalled=True / RetriesExceeded`,
`history[0].status=failed`, and **no reconcile attempt since 2026-07-14** — while the Grafana
pod ran `3/3 Running`, 0 restarts, 72 days, PVC Bound on `ceph-block`. Everything committed
under `infrastructure/grafana/` for two months reached nothing, and no status field said so.

**Two Flux defaults in series produced it:**

1. **No `.spec.timeout`** → Helm allows readiness 5 minutes. The status showed
   `Last Attempted Release Action Duration: 5m0.528513048s` — a *deadline*, not an error. A
   first install provisioning a ceph PVC and pulling images took longer; the pod came up
   moments after Helm gave up.
2. **`install.remediation` with only `retries: 3`.** `remediateLastFailure` defaults **false
   for install** and **true for upgrade**. With it false, every retry attempted an *upgrade*
   of a release whose only version was a failed install — which Helm refuses. Four attempts
   against an error they could never clear.

**Why:** `Ready` describes the reconciler's last attempt; the Helm history describes the
release. They disagree in both directions and the disagreement is the finding. Related:
[[adjacent-step-green-signals]], [[gitops-has-four-stale-layers]].

**How to apply:**

```
kubectl get helmrelease <name> -n <ns> -o jsonpath='{.status.history[0].status}{"\n"}'   # want: deployed
bash scripts/check-helmrelease-truth.sh --context admin@op-usxpress-qa
```

The script compares Ready / Stalled / history / running pods and refuses to collapse them,
and flags the missing `timeout`, the missing `remediateLastFailure` and a floating chart
version whatever the verdict. `scripts/check-onprem-platform-state.sh` checks Kustomizations
and **never looked at HelmReleases** — QA reported 43/43 Kustomizations True with a failed
HelmRelease underneath.

⚠️ **Severity depends on the pods, so count them before ranking it.** *Release broken +
workload down* is an outage someone finds in an hour. *Release broken + workload up* is silent
GitOps paralysis with a half-life of months. A devops agent ranked QA's HIGH and inferred
Grafana was unavailable; it was serving. The observation was right, the inference was not.

⚠️ **`Stalled=True` is terminal per generation.** Reconcile, suspend/resume and waiting all do
nothing — only a spec change (new `metadata.generation`) restarts it.

⚠️ **`helm uninstall` takes the PVC** when the chart owns it and the storage class reclaims
`Delete`. Annotate `helm.sh/resource-policy=keep` or move to `persistence.existingClaim`
*before* enabling `remediateLastFailure`. The annotation is a live edit, not Git.

Fix shipped as `variant-inc/iaac-talos-flux-platform#151` on branch `op-qa`: `timeout: 15m`,
`remediateLastFailure: true`, chart pinned `8.x` → `8.15.0` so the repair's fresh resolve is a
like-for-like restore. **`op-dev` carries the same two defaults** and installed in time by
luck; patch it before its next rebuild. Full record:
`wip/onprem-observability/FINDINGS-2026-09-18-qa-grafana-stalled.md`.

---
name: gitops-has-four-stale-layers
description: "Between a merged PR and a running process there are four caches — GitRepository, Kustomization, HelmRelease, Pod — and each reports Ready while the next is still serving the old thing; verify at the process, not at any layer above it"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 47b0e9a0-2e5c-4874-83f1-06d3268ab121
  modified: 2026-09-03T20:55:10.988Z
---

**2026-09-03, op-prod Grafana.** A merged PR took four separate pushes to reach the process,
and at every stopping point something authoritative said everything was fine.

| layer | what it said | what was true |
|---|---|---|
| GitHub | `op-prod` HEAD = `2511e0e` | ✅ |
| GitRepository `infra` | serving `3fe256fc` | **one commit behind** |
| Kustomization `grafana` | `Ready=True`, applied `3fe256fc` | applied an **old** commit, truthfully |
| ConfigMap (Helm *values*) | updated to `op-prod` after reconcile | HelmRelease had not re-rendered |
| Pod | `3/3 Running`, **age 9d** | running `grafana.ini` from nine days ago |

`scripts/flux-revision-drift.sh` reported **"OK: all 41 Kustomizations are at the revision
their source is serving"** throughout. That statement was *true and useless*: it compares
**applied vs serving**, and when the source is stale both are the same old commit. Nothing in
the repo compared either against the branch HEAD.

**How to apply.**

1. **`lastAppliedRevision` is not "your change is live"** — read the sha and compare it to
   `gh api repos/<org>/<repo>/commits/<branch> --jq .sha`.
2. **A Kustomization applying a ConfigMap of Helm *values* does not re-render the release.**
   The HelmRelease needs its own reconcile before the chart regenerates its config and the
   deployment rolls. `flux reconcile helmrelease <name> -n <ns>`.
3. **Finish at the workload.** Compare the pod's `.status.startTime` against when the config
   changed. A correct value in a ConfigMap or Secret is not the value the process is running
   — the same trap as [[pod-env-secret-resolution]] and the RisingWave console licence, which
   also bit today.
4. When impatient, the sequence that actually pushes it through:
   `flux reconcile source git <src>` → `flux reconcile kustomization <k> --with-source` →
   `flux reconcile helmrelease <hr> -n <ns>`.

**Two probes that told me nothing and were nearly read as findings:**
`curl /api/frontend/settings | .appUrl` returned `None` — the endpoint is **401**, so that was
an auth failure, not a wrong value ([[transport-failure-not-a-verdict]]). And
`curl -sI /login | grep -i location` returning nothing is not evidence either way: `/login`
answers 200 with no redirect whatever `root_url` says. **A check that cannot fail is not a
check.**

Related: [[adjacent-step-green-signals]], [[octopus-green-but-no-apply]],
[[flux-stale-dependency-cascade]], [[proxy-is-not-the-property]].

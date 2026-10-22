---
name: policy-cannot-fix-what-stops-it-running
description: "A cleanup policy enforced BY a process cannot recover from the condition that stops that process starting — Prometheus retention on a full disk deadlocks; break it with space first, then set the policy so it does not recur"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 47b0e9a0-2e5c-4874-83f1-06d3268ab121
  modified: 2026-09-03T20:25:36.290Z
---

**2026-09-03, op-usxpress-dev / risingwave-2.** `prometheus-server` crashlooped **1567
times** over months, exiting 1 on every start:

    write /data/queries.active: no space left on device

`server.retention: "15d"` was **already set** in the HelmRelease. It did not help and never
could have: retention is applied by a **running** Prometheus, and this one died during
startup before reaching it. Once the 10Gi volume filled, the process that would have freed
space could no longer start — a deadlock, not a misconfiguration.

**My first recommendation was backwards**: "fix retention, not size — growing the PVC only
buys weeks." True in general, wrong here. Nothing the policy says matters until something
external breaks the deadlock.

**How to apply.** When a process dies on an exhausted resource, ask *who enforces the limit
on that resource*. If the answer is the dead process, ordering is forced:

1. **Free the resource from outside** — expand the volume, delete data, raise the quota.
   `ceph-block` has `allowVolumeExpansion: true`, so `kubectl patch pvc` resized it online
   with no restart; `local-path` cannot do this.
2. **Then** set the policy, so it does not recur.
3. **Then** make Git say what the cluster says. A live `patch` is drift: the next reconcile
   or rebuild restores 10Gi and the loop starts again.

Same shape elsewhere: log rotation that runs inside the app whose disk is full, a GC thread
that needs an allocation, a cert renewer that needs the expired cert to reach its API.

**Also from this one:**
- A pod can read `2/2 Running` with **1569 restarts** — the healthy sidecar reports Ready
  while the other container cycles. See [[pod-restart-count-is-not-a-live-signal]] in
  `scripts/lib-pod-health.py`, and [[adjacent-step-green-signals]].
- `resources: {}` on both containers meant `automemlimit` read the cgroup limit as **11.2 GB
  — the whole node**. Unbounded workloads on a shared node are a neighbour problem waiting
  to happen.
- The scrape config **looked** corrupt in a `jsonpath | json.tool` dump (missing spaces,
  broken indents) and was **not** — the rendered ConfigMap parsed as valid YAML. A rendering
  artifact read as a defect. Checked before acting; would otherwise have been a PR against
  working config. See [[proxy-is-not-the-property]].

Source of truth: HelmRelease `prometheus` in `manifests/op-usxpress-dev/` of
**`iaac-risingwave-2`** (Flux Kustomization `risingwave` on op-dev). risingwave-2 is
dev-only — see [[risingwave-onprem]].

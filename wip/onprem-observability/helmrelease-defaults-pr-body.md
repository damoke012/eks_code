Applies the fix proven by #151 to the rest of the platform.

`scripts/check-helmrelease-truth.sh` was pointed at op-usxpress-qa on 2026-09-18 after
`grafana/grafana` was found `Stalled / RetriesExceeded` with no install attempt since
**14 July** — 66 days during which nothing committed under `infrastructure/grafana/`
reached the cluster, while the Grafana pod ran `3/3` with 0 restarts and every
Kustomization reported `Ready=True`.

Grafana was not unlucky. It was first.

| Gap | Releases on QA |
|---|---|
| no `.spec.timeout` — Helm allows readiness **5 minutes**, then records a merely slow install as `failed` | **13 of 19** |
| `install.remediation` without `remediateLastFailure` — defaults **false** for install and **true** for upgrade, so every retry attempts to *upgrade* a release whose only version is a failed install, which Helm refuses | **16 of 19** |
| floating chart version — the next reconcile may resolve a different chart than the one running | **6** |

`prometheus/prometheus-stack` and `rook-ceph/rook-ceph` are both in that list.

## Proven before it was widened

#151 made exactly these changes to `grafana/grafana` alone. Merged 2026-09-18 14:02;
`history[0].status` went `failed` → **`deployed`** at 14:08, `Ready=True`. The pattern is
not a theory.

## What changes

- `spec.timeout: 15m` where absent
- `install.remediation.remediateLastFailure: true` where absent
- five floating versions pinned **to the chart that is currently deployed**, read from
  `status.history[0].chartVersion` — not to latest:

| Release | was | pinned to |
|---|---|---|
| `external-secrets/external-secrets` | `2.2.x` | `2.2.0` |
| `keda/keda` | `2.19.x` | `2.19.0` |
| `kyverno/kyverno` | `3.3.x` | `3.3.9` |
| `prometheus/prometheus-stack` | `72.x` | `72.9.1` |
| `velero/velero` | `8.x` | `8.7.2` |

Pinning to the running version means this PR cannot move any chart. It only removes the
possibility of an unplanned move later — which matters most during a *recovery*, when a
fresh chart resolve happens at the same moment as a repair.

## Risk

Low, and asymmetric in the safe direction:

- `timeout` only extends how long Helm waits. It cannot fail something that succeeds today.
- `remediateLastFailure` only acts **on failure**. On a healthy release it is inert.
- pinning matches what is already deployed, so no release changes version.

No running release should be disturbed. Verify with the history, not the Ready condition:

```
bash scripts/check-helmrelease-truth.sh --context admin@op-usxpress-qa
```

Every release should report `history=deployed` afterwards, and the advisory count should
fall to the releases deliberately left alone.

## Deliberately left alone

Releases with **no `install.remediation` block at all** are untouched. Flux defaults install
retries to 0 there; inventing a remediation block would change behaviour beyond this fix and
belongs in its own change with its own reasoning.

## Scope

`op-qa` only — the platform repo uses per-environment branches. **`op-dev` carries the same
two gaps** and installed in time by luck of timing; it needs the same patch before its next
rebuild finds out. `op-prod` is unmeasured.

Generated with `scripts/patch-helmrelease-defaults.py`, which edits textually and anchors on
structure so comments and key order survive — a YAML round-trip would rewrite all eighteen
files and bury this diff.

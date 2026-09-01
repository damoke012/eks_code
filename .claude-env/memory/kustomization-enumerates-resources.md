---
name: kustomization-enumerates-resources
description: A file added to a Flux-managed directory is only applied if that directory's kustomization.yaml lists it — and some on-prem directories enumerate while others do not
metadata:
  type: project
---

In `iaac-talos-flux-platform`, whether a new file reconciles depends on the directory:

| Directory | `kustomization.yaml` | Adding a file |
|---|---|---|
| `infrastructure/istio-ingress/` | **absent** | Flux generates one; the file applies |
| `infrastructure/velero/` | **enumerates resources** | must be added to the list |
| `infrastructure/risingwave-routes/` | **enumerates resources** | must be added to the list |

On 2026-08-31 the RisingWave metastore Velero Schedule was written into
`infrastructure/velero/` and would have sat in git unapplied — the Kustomization would have
reconciled green, and the backup the on-prem metastore depends on would never have run. The
file's own comment warns about a different silent failure and would not have caught this one.

**Why:** "the file is on the branch" is not "the file is applied", and the two directories
behave differently in the same repo, so neither habit is safe.

**How to apply:** after adding any file to a Flux-managed directory, run
`kubectl kustomize <dir>` and grep the output for the resource you just added. Absence from
that output is the whole finding. Related: [[manifests-copied-across-branches]],
[[flux-stale-dependency-cascade]], [[adjacent-step-green-signals]].

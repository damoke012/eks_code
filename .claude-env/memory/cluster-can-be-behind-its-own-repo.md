---
name: cluster-can-be-behind-its-own-repo
description: Flux GitRepositories pinned to a tag mean merging and tagging ship nothing until someone edits the pin — and every object stays green while the cluster sits versions behind
metadata:
  type: project
---

**Measured 2026-10-27.** op-usxpress-prod and op-usxpress-qa both ran
`iaac-risingwave-onprem` **`tag: v0.11.3`** (cut 2026-10-13) while `main` was at **`v0.13.3`**.
Six commits had merged, CI had passed on each, tags had been cut — **none of it was on any
cluster**, and every Flux object was Ready.

**Delivery is four steps and three are invisible from the PR:**

```
merge to main -> a tag is cut -> SOMEONE EDITS THE PIN -> Flux reconciles
```

Only the first is automatic from a developer's point of view. The third has no automation and
**nothing anywhere reports that a cluster is behind its own repo.**

**Why:** a green Kustomization means *the pinned revision* applied cleanly. It says nothing
about whether your change is in that revision. This is [[adjacent-step-green-signals]] with a
whole repository as the adjacent step, and it sits one layer ABOVE
[[gitops-has-four-stale-layers]] — the pin is a fifth layer.

**Where the pins live:** `iaac-talos-flux-cluster`, branch `master`, one monolithic
`clusters/op-usxpress-<env>/flux-system/infra.yaml` per cluster (700+ lines holding every
GitRepository and Kustomization). Path-based, not branch-per-environment, so a PR can move one
cluster's pin without touching the others. See [[onprem-gitops-repo-topology]].

**Precedent to copy:** `db4812c INFRA-1647: promote iaac-risingwave-onprem v0.11.3 to
op-usxpress-prod (#48)`. Promotions are their own PR with that title shape.

**How to apply:**
* Before claiming a merge reached a cluster, read
  `kubectl -n flux-system get gitrepository <name> -o jsonpath='{.status.artifact.revision}'`
  and compare it with the repo's newest tag. **`scripts/check-cluster-behind-repo.sh <env>`**
  does this for every pinned source on a cluster.
* Compare tags with `sort -V`, never `sort`. Lexically `v0.9.0` beats `v0.13.3`, which
  inverts the verdict.
* Being behind is **not automatically wrong** — the pin IS the promotion gate, and that is a
  better gate than branch-tracking. It is wrong when nobody knows.
* Check the per-environment diff before bumping: `git diff --stat <oldtag>..<newtag> --
  manifests/op-usxpress-prod/`. On 2026-10-27 two minor versions carried exactly **three
  lines** for prod, which turned a scary-sounding bump into a trivial one.

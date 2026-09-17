# Promoting RisingWave

`iaac-risingwave-onprem` has one `main` branch and one directory per cluster. Before this change,
every cluster tracked `branch: main` on a 5-minute interval, so **merging a PR deployed it
everywhere at once** — including production, with no release, tag or approval.

Now:

| Cluster | Tracks | Meaning |
|---|---|---|
| `bm-dev` | `branch: main` | always latest. A merge reaches dev in ~5 minutes, as before. |
| `op-usxpress-qa` | `tag: vX.Y.Z` | moves only when someone opens a PR here |
| `op-usxpress-prod` | `tag: vX.Y.Z` | same, and never ahead of QA |

## How to promote

**1. Find the tag.** Every commit on `main` is tagged automatically by CI — lightweight tags,
one per merge.

```bash
cd /tmp && rm -rf iaac-risingwave-onprem
git clone -q https://github.com/variant-inc/iaac-risingwave-onprem.git
git -C /tmp/iaac-risingwave-onprem log --oneline --decorate -10 main
```

Take the **exact patch tag** — `v0.5.6`. Never `v0.5` or `v0`: those float forward on every
release and would leave you with a slower ungated pipeline rather than a gate.

> If the commit you want has **no tag**, the merge produced no release. Releases key on
> conventional-commit prefixes (`fix:`, `feat:`), so a plain commit message can merge cleanly and
> produce nothing to promote. Fix it by landing a follow-up with a proper prefix.

**2. Check dev has actually run it.** A tag is not evidence the code works; dev is.

```bash
kubectl --context op-dev -n flux-system get kustomization risingwave-onprem \
  -o jsonpath='{.status.lastAppliedRevision}{"\n"}'
```

That revision should contain the commit you are about to promote, and the RisingWave pods in
`risingwave` should be healthy and **not recently restarted**.

**3. Open the PR.**

```bash
./pin-risingwave-tag.py --repo . --tag v0.5.6 --clusters op-usxpress-qa            # dry run
./pin-risingwave-tag.py --repo . --tag v0.5.6 --clusters op-usxpress-qa --apply
git diff                    # exactly one line should differ
```

**4. Watch QA reconcile**, then repeat for `--clusters op-usxpress-prod`.

```bash
flux --context op-qa -n flux-system get kustomization risingwave-onprem
```

Ready means the manifests applied. It does not mean the workload is healthy. Every GitOps layer
reports Ready while the next one is still behind — GitRepository, Kustomization, HelmRelease,
Pod — so finish at the pod:

```bash
kubectl --context op-qa -n risingwave get pods
```

## What this does not protect against

- **A bad manifest still reaches dev immediately.** That is the point of dev.
- **`kustomize build` passing is not `kubectl apply` passing.** The 2026-09-15 console freeze
  rendered cleanly and failed server-side apply. A pre-merge
  `kubectl apply --server-side --dry-run=server` against a live cluster is the check that would
  have caught it; this pinning does not add one.
- **`prune: false`** on the RisingWave Kustomization protects Tim's namespace from deletion. It has
  never protected against a bad update.
- **The values that matter are patched elsewhere.** Compute CPU/memory, `stateStore` and the
  operator chart version come from each cluster's `postRenderer` in *this* repo, not from
  `iaac-risingwave-onprem`. Promoting a tag does not change them, and changing them here does not
  require a promotion. Read both.

## Rolling back

Point the tag back and merge. Flux will re-apply the older revision within the interval. Because
`prune: false`, objects added by the newer revision are **not** removed — a rollback leaves them
behind, and they need deleting by hand.

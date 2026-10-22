---
name: risingwave-onprem-has-no-promotion-gate
description: every cluster tracks branch main of iaac-risingwave-onprem at 5m, so merging IS deploying to prod; and the RisingWave CR that lands is patched by a postRenderer in the CLUSTER repo
metadata:
  type: project
---

`iaac-risingwave-onprem` has one `main` and three directories: `manifests/op-usxpress-dev` (34
files), `-qa` (24), `-prod` (24). Each cluster's Flux wiring — in **`iaac-talos-flux-cluster`**,
not in the app repo — points at the same ref:

```yaml
kind: GitRepository
metadata: { name: iaac-risingwave-onprem }
spec:
  interval: 5m0s
  ref: { branch: main }          # verified on dev, QA AND prod 2026-09-17
```

Only `path` differs per cluster. **A merge touching `manifests/op-usxpress-prod/` reaches prod in
about five minutes**, with no release, tag or approval. The one pre-merge check,
`manifest-lint.yaml`, runs on `pull_request` and does `kustomize build` — it proves the YAML
renders, never that it can apply to the object that already exists, which is precisely the
2026-09-17 failure ([[server-side-apply-keeps-dropped-fields]]).

`prune: false` on the RisingWave Kustomization is deliberate protect-RW insurance against
deletion. It does nothing about a bad update.

**The CR in git is not the CR in the cluster.** A `postRenderer` in the cluster repo patches
compute `resources.requests`/`limits`, `/spec/stateStore`, meta and frontend env, and the
operator's `/spec/chart/spec/version`. So RisingWave's machine sizes and the operator version are
per-cluster and live in a different repo — and the patches are index-based
(`nodeGroups/0`, `env/-`), so they retarget silently ([[kustomize-index-patches-are-fragile]]).

The Terraform half (`deploy/`) is fine: it goes through Octopus and keeps the `TfApply` gate.

**Why:** this is the one repo that cannot obey [[promotion-order-qa2-dev-qa-prod]], and it owns
the database.

**How to apply:** never review a PR here from this repo alone — read the cluster's `postRenderer`
too. To fix the gate, pin each cluster to `ref: { tag: ... }` (the repo already tags v0.5.6/v0.5/v0)
and promote by moving the tag per environment; dev can stay on `branch: main`. That is one line
per cluster in `iaac-talos-flux-cluster` and needs no restructuring.

## 2026-10-08 — "master is the source of truth" is TRUE for one repo and FALSE for this one

Said on a call, unqualified, to the application owner: *"Master is the source of truth. You
push to master, then you create a promotion from master to QA."*

That describes **`risingwave-pipeline`**, which really does promote by digest per environment.
It is wrong about **`iaac-risingwave-onprem`**, where all three clusters track `branch: main`
at 5m and a merge reaches prod unreviewed in about five minutes.

**How to apply:** never state a branch model without naming the repo. The two sit one sentence
apart in the same conversation, and the person acting on it owns the pipeline, not the
platform — so the version they remember is the permissive one. Same shape as the Octopus/GitHub
pair in that call: RisingWave's Terraform still deploys through Octopus with the `TfApply` gate
while the pipeline deploys through GitHub, and "just replace Octopus with GitHub" reads as
universal.

## ⚠️ CORRECTED 2026-10-12: prod does NOT track main — it tracks a TAG

Measured on op-usxpress-prod: `gitrepository/iaac-risingwave-onprem` has
`spec.ref = {"tag":"v0.5.6"}`, and both Kustomizations (`risingwave-onprem` at
`./manifests/op-usxpress-prod`, `risingwave-operator` at `.../operator`) reconcile
`v0.5.6@sha1:62e56b3dd6ebdd42255b3f14a6340b2071fbc82f`.

**So merging to `main` cannot reach prod.** The claim above — "every cluster tracks
`branch: main` at 5m so merging IS deploying to prod" — is false for prod. **Prod has a
real promotion gate.** Reaching it takes two deliberate acts: cut a tag on
`iaac-risingwave-onprem`, and point prod's GitRepository ref at it.

How this surfaced: PR #46 bumped prod's operator chart 0.1.36 → 0.1.40 (operator v0.16.0 →
v0.18.0), was merged to `main`, and after 7 minutes nothing moved — operator still v0.16.0,
CRD still `generation=1`.

**Tested and killed** on the way to the real cause: that the prod Kustomization did not
enumerate the `operator/` subdirectory (it does — `operator/kustomization.yaml` lists
`operator-helmrelease.yaml`); and that the live operator was applied by hand outside GitOps
(it is not — the Deployment carries `helm.toolkit.fluxcd.io/name: risingwave-operator`,
`meta.helm.sh/release-name`, and `helm.sh/chart: risingwave-operator-0.1.36`, and the
HelmRelease is `Ready`). Everything is correctly managed; it simply is not looking at `main`.

**A tag is a bundle, not a cherry-pick.** Cutting a new tag carries EVERY commit on `main`
since `v0.5.6` into prod, so read `compare/v0.5.6...main` in full first (CLAUDE.md rule 7).

Still unmeasured: dev's and QA's refs. Dev behaved like `main` (PR #45's `wal_level` reached
it within minutes on 2026-10-09), so the ref model may differ per environment — which would
make this repo's promotion story per-cluster, not global. Verify before repeating either
claim. Related: [[rw-prod-blocked-on-manifests-path]], which repeats the same wrong premise
and should be read with this correction.

## The real promotion model, measured 2026-10-12

| env | GitRepository ref | effect |
|---|---|---|
| dev | `branch: main`, 5m | a merge deploys immediately |
| QA | exact `tag:` | gated |
| prod | exact `tag:` | gated |

Prod and QA are moved by **`scripts/pin-risingwave-tag.py` in `iaac-talos-flux-cluster`
@ `master`**, editing `clusters/<cluster>/flux-system/infra.yaml`. It is a careful script:
refuses floating tags (`v0`, `v0.5`), refuses if more than one GitRepository document matches
the repo URL, and asserts exactly one changed line before writing. `branch: main` appears many
times in that file for other sources, which is why it exists instead of sed.

⚠️ **Its `DEFAULT_CLUSTERS` is `["op-usxpress-qa", "op-usxpress-prod"]`** — running it without
`--clusters` moves QA as well as prod.

⚠️ **It could not MOVE a tag.** Given an existing `tag:` it returned `already pinned, nothing
to do` and exited 0, so `v0.5.6 -> v0.6.0` silently did nothing — the same shape as every other
failure in this workstream: a true statement about the step next to the one that matters. Fixed
2026-10-12 in `iaac-talos-flux-cluster#43`, keeping all its safety properties.

Tags are minted per commit on main (`v0.5.7`, `v0.5.8`, `v0.5.9`, `v0.6.0`) plus a floating
`v0.6`. Neither `octo.yaml` nor `manifest-lint.yaml` appears to cut them — the tagger is still
unidentified.

**So a prod release is three acts:** merge to `main`, a tag exists at that commit, then move the
pin in the *cluster* repo. A merge alone changes nothing on prod, and PR #46 looked
merged-and-done for 40 minutes while prod sat on `v0.5.6`.

**Proven 2026-10-12:** prod operator v0.16.0 -> v0.18.0 (chart 0.1.36 -> 0.1.40) landed via
this path; CRD `generation` moved 1 -> 2, confirming `crds: CreateReplace`; and the data plane
did NOT move because the CR pins `spec.image` explicitly — all five RisingWave pods stayed on
v2.8.2 with 0 restarts. A CR that leaves `spec.image` unset would have taken the operator's own
default (v3.0.3 for v0.18.0) and collapsed two planned steps into one.

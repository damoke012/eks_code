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

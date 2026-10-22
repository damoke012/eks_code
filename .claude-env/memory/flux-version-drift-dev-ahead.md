---
name: flux-version-drift-dev-ahead
description: on-prem clusters run DIFFERENT Flux versions and dev is the one ahead (bm-dev v2.8.8, QA and prod v2.7.5) — so "prove it on dev first" is invalid for anything Flux-behavioural
metadata:
  type: project
---

Measured 2026-09-17 from `clusters/<cluster>/flux-system/gotk-components.yaml` in
`iaac-talos-flux-cluster`:

| Cluster | Flux |
|---|---|
| `bm-dev` | **v2.8.8** |
| `op-usxpress-qa` | v2.7.5 |
| `op-usxpress-prod` | v2.7.5 |

**Why it matters:** server-side apply, `removed` block handling and dry-run semantics can
change between Flux minors. A reconcile proven on dev is therefore **not** evidence for QA or
prod, and the promotion order QA2 → dev → QA → prod
([[promotion-order-qa2-dev-qa-prod]]) silently assumes a parity that does not exist. It cuts
both ways: the console dry-run failure fixed on QA on 2026-09-15 was a v2.7.5 behaviour, and
dev may not reproduce it.

**How it happened:** `flux bootstrap` installs whatever version the local CLI ships. Nothing
pins it, nothing compares across clusters, and the version only appears inside a generated
manifest nobody diffs — `gotk-components.yaml` is routinely excluded from comparisons because
it is large and machine-written.

**How to apply:** bootstrap a new cluster on the version QA and prod run, not the newest, or
it proves things about a version production does not have. Check before trusting any
cross-environment reasoning about Flux:

```
for C in bm-dev op-usxpress-qa op-usxpress-prod; do echo -n "$C: "; \
  grep -m1 -o 'app.kubernetes.io/version: [^ ]*' clusters/$C/flux-system/gotk-components.yaml; done
```

Related: [[server-side-apply-keeps-dropped-fields]], [[gitops-has-four-stale-layers]],
[[manifests-copied-across-branches]].

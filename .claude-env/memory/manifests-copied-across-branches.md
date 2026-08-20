---
name: manifests-copied-across-branches
description: iaac-talos-flux-platform per-cluster branches are copies; cluster-specific values silently keep dev's identifiers
metadata:
  type: feedback
---

`iaac-talos-flux-platform` branches (op-dev / op-qa / op-prod) are copies of each
other, not per-cluster configurations. On 2026-08-18
`infrastructure/ecr-credentials/` was byte-identical across all three (same blob
hashes) and all three annotated the DEV IRSA role
`700736442855:role/op-usxpress-dev-ecr-credentials-sync`. Only op-dev consumed the
directory, so nothing ever surfaced.

**Why:** a directory that is not wired on a cluster is never exercised, so wrong
cluster-specific values sit there indefinitely and fail the moment someone wires it.
The failure is a *green* Kustomization plus a workload that cannot authenticate —
STS returns `InvalidIdentityToken` when the token's issuer is not a registered
provider in the role's account.

Four instances found on 2026-08-18: (1) ecr-credentials rbac.yaml naming dev's IRSA role
on all three branches; (2) ecr-credentials never wired on QA or prod at all; (3)
risingwave-routes on op-qa carrying `rw-sql.op-dev.usxpress.io` and dev node addresses;
(4) those same routes binding to a `tcp-passthrough` Gateway that does not exist on QA, so
QA has no L4 RisingWave access. Tracked as INFRA-1645 (the routes) and INFRA-1646 (a
pre-merge grep for foreign cluster identifiers).

Note the contrast in (3): the HTTP VirtualServices WERE adapted per-cluster
(`risingwave-dashboard.op-qa.usxpress.io` → QA nodes). Only the TCP passthrough ones were
copied unchanged — so "this directory was adapted" is not safe to infer from a sibling.

**How to apply:** before wiring an existing platform directory onto a new cluster,
diff it against the branch it was copied from and grep for account IDs, role ARNs,
issuer URLs and cluster names. Verify with the workload's own logs, never the
Kustomization status. See [[eso-secretsynced-not-content-check]] and
[[onprem-app-cicd]].

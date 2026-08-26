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

**Instances five and six, 2026-08-20** — the family is not limited to platform branches; app
overlays inherit the same way:
* `deploy/overlays/qa/endpoints.yaml` carried `postgres-postgresql…`, a dev service name.
  QA runs `pg-postgresql`.
* The same file asserted `PG_USER: postgres` and `PG_DB: postgres`; Secrets Manager held
  username `risingwave` and the StatefulSet's `POSTGRES_DB` is `risingwave`.

**Check now written:** `scripts/verify-overlay-endpoints.sh <endpoints.yaml> <context>` —
resolves every `*.svc.cluster.local` name against the target cluster and lists the real
services when one misses. Run it before the PR, not after the failed sync.

**Rule learned the hard way:** a username and password that live in one secret must travel
together. Split across a ConfigMap and Secrets Manager they drift, and the error names the
wrong cause — `password authentication failed for user "postgres"` when the real user is
`risingwave`.

**Check written 2026-08-20 (INFRA-1646, closed):**
`scripts/check-foreign-cluster-ids.sh <platform-checkout> <op-dev|op-qa|op-prod> [--diff <base>]`
scans for the other clusters' account IDs, OIDC issuers, API node addresses and DNS suffixes
and exits non-zero on a hit; `--diff` limits it to changed files for pre-merge use. The
shared ECR account 064859874041 is deliberately not flagged. Run it before every platform PR.

**2026-08-21 — it also happens WITHIN one branch, and the stale copy can live in the notes
repo.** `wip/onprem-app-cicd/platform/` was treated as a staging mirror of the cluster branch.
It is not maintained as one. PR #100 copied a stale file from there over the branch and
reverted an ApplicationSet's `repoURL` from `ssh://` to `https://`, taking op-qa delivery down
for 18 hours. `check-foreign-cluster-ids.sh` passed it — that check looks for *another
cluster's* identifiers, not for a regression against what is already deployed. Now CLAUDE.md
rule 7. See [[onprem-app-cicd]].

## 2026-08-24 — confirmed LIVE at the ingress layer, not just on branches

**op-qa is serving `grafana.op-dev.usxpress.io`.** Its Grafana VirtualService on the running
QA cluster claims a dev hostname. Dev serves the same name. Two clusters claim one DNS record,
both running external-dns against zone `usxpress.io`; as of 21:50 it resolved to dev's seven
nodes, so whichever wrote last wins. Opening dev's Grafana URL can land you on QA's.

`op-prod`'s branch carries the same copied file plus `credentialName: wildcard-op-qa-tls` on
its shared gateway — **branch content only, NOT verified live.** Nothing under `~/.kube`
reaches 10.10.82.52; prod checks that day were break-glass and were not persisted.

Found by `scripts/onprem-ingress-audit.sh`, which groups every claimed hostname by suffix so a
foreign one shows as a count rather than something to spot by eye. It compares each cluster
against **itself**, which is why it caught a cluster nobody was looking at.



**Instance seven, 2026-08-25 — op-prod's ENTIRE ingress layer is dev's.** All **5 of 5**
non-templated VirtualServices on the `op-prod` branch carry `*.op-dev.usxpress.io` hostnames
and are annotated with dev's seven worker IPs
(`10.10.82.21,.22,.26,.27,.28,.178,.180`): grafana, and all four risingwave-routes. Found
because a builder refused to copy route wiring from a foreign-hostname route — the guard added
after QA was caught live-serving `grafana.op-dev.usxpress.io`.

Consequence if those Kustomizations reconcile: prod's external-dns publishes op-dev records
pointing at op-dev nodes, and two external-dns instances contend for them, arbitrated only by
`txtOwnerId`. Unconfirmable without cluster access (INFRA-1663). This also blocks the Argo
route on prod: there is no correct route on the branch to derive DNS targets from, and targets
are not portable between these clusters.


**Counter-example, 2026-08-25 — it is a prior, not a law.** op-prod's external-dns carries
`--txt-owner-id=iaac-talos/us-east-2/op-usxpress-prod`, genuinely per-cluster, and a
`--domain-filter` broad enough for all three. Predicted instance ten; there wasn't one.

**How to apply:** the pattern covers files **written by hand and copied between branches**
(Gateways, Certificates, VirtualServices, ClusterIssuers). It does **not** cover values a
module already templates per cluster. Check before predicting — calling it everywhere sends
you to fix things that are correct.

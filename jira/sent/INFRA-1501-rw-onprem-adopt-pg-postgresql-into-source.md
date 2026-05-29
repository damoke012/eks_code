---
key: INFRA-1501
status: filed
assignee: Idris Fagbemi
reporter: Doke
created: 2026-05-29
filed: 2026-05-29
parent_link: INFRA-1487 (Relates — INFRA-1487 is itself a sub-task so we linked rather than sub-tasked)
initiative: rw-onprem-flux
---

# Adopt hand-deployed `pg-postgresql` into iaac-risingwave-onprem source

## Context
The postgres instance RisingWave actually depends on (`pg-postgresql`, ns `risingwave`, running 29+ days) is hand-deployed and not in any source manifest. After PR #7 ([INFRA-1487](https://usxpress.atlassian.net/browse/INFRA-1487)) merges, Flux manages the RW CR, console, operator, and the new (currently unused) `postgres` HR — but `pg-postgresql` continues to live outside GitOps. That's an ongoing drift risk on a critical RW dependency: an admin upgrade, password rotation, or accidental delete won't be visible to Flux, and there's no way to redeploy from source if the running pod is lost.

This is the second of two follow-ups from PR #7 approval 2026-05-29 (the first is A1: remove the unused `postgres` HR).

## Scope

**In:**
- Add a `pg-postgresql-helmrelease.yaml` to `iaac-risingwave-onprem/manifests/op-usxpress-dev/` that matches the hand-deployed pg-postgresql release exactly (chart, version, values, existingSecret).
- Adopt the existing live release into the new HR (no re-install, no pod restart) using one of the patterns below.
- Verify Flux reconciles the new HR cleanly and shows Ready=True without restarting the pg-postgresql pod.
- Decide and document the long-term strategy: keep both `pg-postgresql` (legacy) AND `postgres` (new) until A1 closes, OR migrate fully to one of them.

**Out (explicitly):**
- Changes to RW CR — `metaStore.host` continues to reference `pg-postgresql.risingwave.svc.cluster.local`.
- Touching the `postgres-postgresql` instance (covered by A1).
- Changing anything in `risingwave-2`.
- Postgres password rotation (separate ticket if needed; see [[feedback_protect_rw_onprem_workload]]).

## Definition of done
- [ ] `manifests/op-usxpress-dev/pg-postgresql-helmrelease.yaml` matches the running release (`helm get values pg-postgresql -n risingwave > /tmp/current.yaml` and reconcile).
- [ ] Flux reconciles the new HR with `Ready=True`, no pod restart on `pg-postgresql-0`.
- [ ] RW continues `Running=True` throughout and after.
- [ ] Tim's connection (psql or app) still works post-reconcile.
- [ ] A short note in this ticket explaining the long-term postgres plan (single pg-postgresql, or migrate to `postgres`, or both).

## Suggested approach
Capture the running release first:
```bash
helm list -n risingwave | grep pg-postgresql
helm get values pg-postgresql -n risingwave > /tmp/pg-postgresql-values.yaml
helm get manifest pg-postgresql -n risingwave > /tmp/pg-postgresql-manifest.yaml
```

Then author the HR. **Key gotcha**: Flux HR adoption requires the existing release to have specific labels/annotations, OR you set `install.crds: CreateReplace` + leave the release alone. The safest path is:
1. Author the new HR with `install.skipCRDs: true`, `upgrade.disableWait: false`, `chart.spec.version` matching the current installed version exactly.
2. Add `metadata.annotations.helm.toolkit.fluxcd.io/disable-take-ownership: "true"` if needed, OR
3. Use `kustomize patch` to label the existing Helm Secret (`sh.helm.release.v1.pg-postgresql.v*`) with `helm.toolkit.fluxcd.io/name=pg-postgresql` + `helm.toolkit.fluxcd.io/namespace=risingwave` so Flux recognizes ownership.

Test the reconcile on a feature branch first against the live cluster (point an existing Kustomization at the branch, or `flux build` + `flux diff`).

## Constraints
- No Octopus access required.
- Cluster-admin needed for reconcile testing.
- **Tim coord required** per [[feedback_protect_rw_onprem_workload]] — this touches the postgres RW depends on. Pre/post checks (RW Running=True, psql succeeds).
- Cannot let the pg-postgresql pod restart — that's an outage for Tim. Use `prune: false` on the Kustomization (which is already the case in PR #7).

## Links
- WIP doc: [`wip/rw-onprem-flux/STATE.md`](../../wip/rw-onprem-flux/STATE.md)
- PR #7 (parent): https://github.com/variant-inc/iaac-talos-flux-cluster/pull/7
- Source repo: https://github.com/variant-inc/iaac-risingwave-onprem
- Helm Flux adoption docs: https://fluxcd.io/flux/components/helm/helmreleases/#adoption-of-existing-helm-releases
- Parent epic: [INFRA-1487](https://usxpress.atlassian.net/browse/INFRA-1487)
- Related: A1 (remove dead postgres HR) — these two are paired; do A2 first, then A1.

## Estimate
M — one PR + Flux adoption testing + Tim coord. ~half-day including a careful rehearsal of the adoption on the live release.

---
key: INFRA-1500
status: filed
assignee: Idris Fagbemi
reporter: Doke
created: 2026-05-29
filed: 2026-05-29
parent_link: INFRA-1487 (Relates — INFRA-1487 is itself a sub-task so we linked rather than sub-tasked)
initiative: rw-onprem-flux
---

# Remove unused `postgres` HelmRelease from iaac-risingwave-onprem source

## Context
`iaac-risingwave-onprem/manifests/op-usxpress-dev/postgres-helmrelease.yaml` provisions a postgres HR named `postgres` (currently running as `postgres-postgresql-0`, came up ~2026-05-29 13:00 UTC). Nothing in the source repo references it — the RW CR and risingwave-console both connect to the legacy `pg-postgresql.risingwave.svc.cluster.local`. The dead HR consumes worker memory/CPU and confuses future readers ("which postgres is real?"). A local `POSTGRES_FOLLOWUP_PLAN.md` exists but is `.gitignore`'d, so the team can't see the plan.

This is one of two follow-ups from PR #7 ([INFRA-1487](https://usxpress.atlassian.net/browse/INFRA-1487)) approval 2026-05-29.

## Scope

**In:**
- Decide one of: (a) delete `postgres-helmrelease.yaml` + `postgres-externalsecret.yaml` from the source and let Flux prune the running pod, OR (b) keep them but rewire the RW CR + console to use the new `postgres` instead of `pg-postgresql` (migration path).
- Make the local `POSTGRES_FOLLOWUP_PLAN.md` visible — either commit it as `docs/postgres-followup-plan.md` or paste its content into this ticket / Confluence.
- If (a) chosen: ensure prune semantics in the Flux Kustomization wouldn't take out `pg-postgresql` (the one actually in use) — `pg-postgresql` is NOT in source so `prune: true/false` doesn't matter for it, but verify.
- If (b) chosen: this becomes ticket A2's migration plan — close this one and execute under A2.

**Out (explicitly):**
- Touching the legacy `pg-postgresql` (covered by A2: adopt-into-source).
- Changing anything in `risingwave-2` namespace.
- Cluster-side cleanup before the source change merges (drift will resolve naturally on next reconcile).

## Definition of done
- [ ] A decision recorded in this ticket: option (a) delete-and-prune, or option (b) migrate-and-adopt.
- [ ] If (a): PR opened on `iaac-risingwave-onprem` removing the two files; merged; Flux reconcile observed; `kubectl get pods -n risingwave -l app.kubernetes.io/instance=postgres` returns empty.
- [ ] If (b): close this ticket; create execution sub-ticket under A2 with the migration plan.
- [ ] `POSTGRES_FOLLOWUP_PLAN.md` is visible to the team (committed under `docs/` OR pasted into this ticket / Confluence) and removed from `.gitignore`.

## Suggested approach
Option (a) is simpler and aligns with current state (RW already on `pg-postgresql`, working). Option (b) is correct if there's a known need to deprecate the legacy postgres.

If (a):
```bash
cd iaac-risingwave-onprem
git checkout -b followup/remove-dead-postgres-hr main
git rm manifests/op-usxpress-dev/postgres-helmrelease.yaml \
       manifests/op-usxpress-dev/pg-externalsecret.yaml  # keep ONLY if it backs postgres-postgresql
# Make sure the Flux Kustomization on iaac-talos-flux-cluster still has prune: false
# so we don't lose anything we didn't mean to.
```

Verify on a test reconcile first (point a non-prod Kustomization at the branch) before merging.

## Constraints
- No Octopus access required.
- Cluster-admin needed for the post-merge verification.
- Tim coord required per [[feedback_protect_rw_onprem_workload]] — the postgres being removed is NOT what RW uses, but verify with Tim before final reconcile in case he was about to migrate.

## Links
- WIP doc: [`wip/rw-onprem-flux/STATE.md`](../../wip/rw-onprem-flux/STATE.md)
- PR #7 (parent): https://github.com/variant-inc/iaac-talos-flux-cluster/pull/7
- Source repo: https://github.com/variant-inc/iaac-risingwave-onprem
- Parent epic: [INFRA-1487](https://usxpress.atlassian.net/browse/INFRA-1487)

## Estimate
S — one PR on iaac-risingwave-onprem, verify on Flux reconcile, capture POSTGRES_FOLLOWUP_PLAN content. ~2 hours including the test reconcile.

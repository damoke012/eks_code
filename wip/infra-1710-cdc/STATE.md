# INFRA-1710 — enable CDC (`wal_level=logical`) — state at 2026-10-08

**Decision: DO NOT MERGE PR #41 yet. Four blockers, and the first one may make the whole
change unnecessary.**

`variant-inc/iaac-risingwave-onprem` **#41**, by `ifagbemi-usxpress`, assigned to `dare-x`.
+4 lines across 3 files. Round 1 drafted at `PR41-round1-comment.md`, not yet posted.

## The blockers, in the order they matter

| # | Blocker | Settles it |
|---|---|---|
| 1 | **Probably the wrong database.** `pg-postgresql.risingwave` is RisingWave's **meta store**, not a CDC source. Tim asked about "the PostgreSQL servers" because he wants RisingWave to *ingest* change data; his sources are SQL Server (`usxsqlrisingwave*`). | One question to Tim |
| 2 | **The test plan cannot happen.** Dev → QA → prod sequencing is impossible: one merge to `main` reaches all three in ~5 min, no gate | Split into three PRs, one per `manifests/op-usxpress-<env>/` |
| 3 | **Dev and QA/prod use different mechanisms** — Helm `primary.extendedConfiguration` vs StatefulSet container args — so a green dev validates neither. Also unconfirmed that the Bitnami entrypoint passes `args` to `postgres`, and that the StatefulSet edit can apply to the live object | `kubectl get sts pg-postgresql -o jsonpath='{...command}{...args}'` on QA and prod |
| 4 | **Restarts RisingWave's meta store on prod.** "Reconnects automatically" is an expectation, not an observation. No Alertmanager delivery on-prem if it does not | Observe it on dev: meta pod restart count, reconnect log line, a query served after |

Advisory: QA/prod run PG as a raw StatefulSet while dev runs the Bitnami chart. That drift is
why one setting needs two edits. Own ticket.

## Not evidence

Both red checks on #41 are **constants**, measured 2026-10-08:

* `dpl` Octopus deploy — **7 failures / 7 statuses, zero successes ever**, since 2026-08-12
* `Manifest Lint / Terraform Validate` — **5/5** since 2026-09-15, including merged PRs

Neither says anything about this change. Both need their own tickets
([[risingwave-onprem-two-delivery-paths]]).

## Proven

* Idris measured the live values and they are right to act on: `wal_level=replica`,
  `max_replication_slots=10`, `max_wal_senders=16`. Only `wal_level` needs changing for CDC.
* The repo has no promotion gate — every cluster tracks `branch: main` at 5m
  ([[risingwave-onprem-has-no-promotion-gate]]). Confirmed again today by watching PR #40
  reach op-dev within one poll.

## Tested and killed

* **"The red checks mean something is wrong with this PR."** They are the floor.
* **"Dev first, then QA, then prod."** Not available from one merge in this repo.

## Traps

1. **A dry-run rejection fails the WHOLE Kustomization**, not one object. `#36` froze this
   namespace for ~4h on 2026-09-15 with every other signal green
   ([[server-side-apply-keeps-dropped-fields]]).
2. **The meta store is infrastructure, not data.** Restarting it is a RisingWave event, not a
   database maintenance window.
3. **Enabling a capability on the wrong server looks identical to enabling it on the right
   one** — both end in `SHOW wal_level` returning `logical`. The verification in the PR would
   pass while delivering nothing.

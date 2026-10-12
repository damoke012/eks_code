# RisingWave version: where we are, and what to upgrade to

Measured 2026-10-12.

## The premise, tested and killed

The suspicion was that Tim's POC pipeline changes were forced by a RisingWave version
difference. They were not.

**There is no version drift.** dev and prod are byte-identical:

| | dev | QA | prod |
|---|---|---|---|
| risingwave | `v2.8.2` | not measured (SSO expired) | `v2.8.2` |
| risingwave-operator | `v0.16.0` | — | `v0.16.0` |
| risingwave-console | `v0.7.4` | — | `v0.7.4` |

Since dev and prod run the same build, a version difference cannot explain anything we
changed. What we actually changed in `usxpressinc/risingwave-poc` was:

* both sink files, from four placeholders (`%MONGODB_USERNAME%`, `%MONGODB_PASSWORD%`,
  `%MONGODB_HOST%`, `%MONGODB_PORT%`) to one `%MONGODB_CONNECTION_STRING%`. No RisingWave
  version accepts those four separately for a Mongo sink; Atlas is SRV-only, so there is no
  host/port pair to compose, and the four were never supplied as env vars anyway.
* path and regex corrections — `100-Brand/` vs `Brand/`, `300-Employee/` vs lowercase
  `employee`.
* the `entities` database name.

None of those move with a release.

## But the upgrade is now justified anyway

**v2.8 left support on 2026-10-11 — yesterday.** All three environments are one day past
end-of-support, which means no bug fixes and no security patches.

(Corrected in place: an earlier read of a garbled snippet put v2.8's EOS at 2026-03-02. That
date belongs to a different version. v2.7 ended 2026-06-11; v2.8 ended 2026-10-11.)

## Target: v3.1.x, not v3.0

* **v3.1.0** released 2026-09-21 and is the current stable line.
* **v3.0** is supported only "upon the release of v3.2". Minor versions ship every 45–75
  days and v3.1 landed 21 September, so v3.2 is roughly 1–2 months out. Upgrading to v3.0
  buys a runway that expires almost immediately.
* Staying on the 2.8 line is not an option worth taking: `v2.8.5` is the latest patch there,
  but a patch inside an end-of-support line buys nothing.

## Gate 1 — the operator, and it is NOT verified

`risingwave-operator` is `v0.16.0` on dev and prod. The operator README's compatibility
table gives only **minimums** — `v0.5.0+` with RisingWave `v0.19.0+` — and says nothing
about 3.x having been tested. It also warns that compatibility between operator versions
may be broken, and points at a "stable manifests" set maintained for the latest release.

So: nominally in range, **actually unproven**. This is the first thing to test, and it is
the thing that would stop the whole project. Do not plan dates before it is answered.

## Gate 2 — what the upgrade itself does to a running pipeline

Three things, all of which touch exactly what dev now runs:

1. **Meta store migration.** Our meta store is `pg-postgresql` in the `risingwave`
   namespace — the Postgres we restarted for `wal_level`. The schema is created with
   `risectl meta create-meta-store-schema`, and the **risectl version must match the
   snapshot version** for any restore. A 2.8 snapshot needs risectl 2.8. Take the backup
   BEFORE upgrading, and keep the matching risectl, or the backup is not a rollback.
2. **Background table migration.** 3.x runs one at upgrade time
   (`enable_legacy_table_migration`). While a table has not finished migrating you
   **cannot create or drop a sink-into-table** on it. Tim has four sinks.
3. **A flagged correctness fix to `SOME`/`ALL`/`ANY`** whose guidance is to **drop and
   recreate affected materialized views**. Dev's pipeline is materialized views feeding
   sinks, so this needs auditing against his SQL before, not during.

## What actually changes, 2.8 -> 3.x

No labelled breaking-changes section exists in the v3.0 or v3.1 notes. Everything below came
from the changelog body and the launch post, which is itself the warning: read the full notes,
do not trust a summary.

* **DataFusion becomes the default analytical engine.** An internal query-engine swap — the
  single change most likely to alter plan behaviour or performance on existing materialized
  views.
* Apache Iceberg V3, native pgvector ingestion, WebSocket and HTTP connectors, exactly-once
  delivery.
* A `VARIANT` type, periodically refreshed materialized views, partitioned gap filling, more
  control over backfill and sink operations.
* Secrets inside UDFs, and dependency tracking for secrets.
* Richer system catalogs, better connector metrics, configurable join cache eviction,
  adaptive parallelism changes.

## Ports — and why ours say 4567

RisingWave's own documented frontend port is **4566**; that is what their local playground
prints. The **operator** defines `FrontendPort = 4567` as a constant in its API package, and we
deploy via `risingwave-operator`. So 4567 is the operator's default, not a local
customisation of ours, and it disagrees with the product docs. Same package: meta 5690, meta
dashboard 5691, compute 5688, compactor 6660.

That splits the port risk cleanly:

| Change | Port risk |
|---|---|
| RisingWave image `v2.8.2` -> `v3.1.x` | **none** — ports are operator constants, not image behaviour |
| `risingwave-operator` `v0.16.0` -> newer | **real** — this is where 4567 could move |

So the version bump is port-neutral. If Gate 1 forces an operator upgrade, 4567 reaches
further than the CR: both ghostunnels, the `tcp-passthrough` Gateway (4567/5432), the
VirtualServices, `RW_PORT` in all three values files, and anything hardcoded in Tim's SQL.
The meta store's 5432 is Bitnami Postgres and is unaffected either way.

## Staging — and it IS stageable

Despite `iaac-risingwave-onprem` having no branch-based promotion gate (every cluster's Flux
GitRepository tracks `main` at 5m), the version is declared **per environment**:
`manifests/op-usxpress-dev/risingwave-cr.yaml`, and the same file under `op-usxpress-qa`
and `op-usxpress-prod`. So a one-environment bump is a one-file change, and QA2 → dev → QA
→ prod is achievable here.

## ✅ ALL THREE DONE 2026-10-12 — operator v0.18.0 + RisingWave v3.0.5

| env | ref | operator | RisingWave | evidence |
|---|---|---|---|---|
| prod | `tag: v0.7.0` | v0.18.0 | v3.0.5 | `select version()` |
| dev | `branch: main` | **v0.16.0 — not bumped** | v3.0.5 | `select version()`, slot `active`, LSN advanced |
| QA | `tag: v0.10.0` | v0.18.0 | v3.0.5 | `select version()`, probe MVs intact |

Order: prod (empty, proved the mechanism), dev (first migration over real state), QA (last).
Operator and image went as **two separate tags and pins** in each environment, so any port or
CRD surprise would be attributable. Rollout 4–8 minutes each, dominated by the 2.49 GB pull.

**Open: dev's operator is still v0.16.0.** Its `operator-helmrelease.yaml` sits directly under
`manifests/op-usxpress-dev/` rather than in an `operator/` subdirectory like QA and prod, and
was never bumped. dev runs 3.0.5 under v0.16.0 — functional, but not the tested pairing.

**Open, and more interesting: QA has never run a Brand pipeline.** 0 sources, 0 sinks, only the
two platform probe MVs — while its ETL sync hook reports Succeeded. Likely the
`pipeline_applied` ledger skipping files whose objects no longer exist. Unproven; see
`green-hook-over-an-empty-cluster` in memory for the verification.

## ✅ PROD DONE 2026-10-12 — and the promotion model we did not know about

Prod is on **operator v0.18.0 + RisingWave v3.0.5**, verified by `select version()`.

The route, which nobody had written down:

| env | GitRepository ref | how it changes |
|---|---|---|
| dev | `branch: main`, 5m | a merge deploys immediately |
| QA | exact `tag:` | tag + pin |
| prod | exact `tag:` | tag + pin |

A prod release is **three acts**: merge to `main`, a tag appears at that commit (automatic,
~60s, minor bump plus a floating `vX.Y`), then move the pin with
`scripts/pin-risingwave-tag.py --clusters op-usxpress-prod --apply` in
**iaac-talos-flux-cluster**. PR #46 looked merged-and-done for 40 minutes while prod sat on
`v0.5.6`, because a merge alone reaches nothing but dev.

Two gotchas found doing it:

* The pin script **could not move an existing tag** — it only converted `branch:` to `tag:`,
  and returned "already pinned, nothing to do" with exit 0 for the operation we needed. Fixed
  in `iaac-talos-flux-cluster#43`.
* Its `DEFAULT_CLUSTERS` is QA **and** prod, so `--clusters op-usxpress-prod` is mandatory
  unless you mean to move both.

### Target, corrected

**v3.0.5, not v3.1.0.** The operator tracks the 3.0 line: its CI bumps the image tags to
v3.0.0, then v3.0.2, then v3.0.3 in v0.18.0, and no operator release mentions 3.1. 3.0.x with
v0.18.0 is the pairing the vendor tests together. v3.0 loses support when v3.2 ships, so expect
another bump in 1-2 months.

### What prod proved, and what it did not

**Proved:** the operator jump, the 1381-line CRD replace via `CreateReplace`, the image
rollout, and that the frontend port stays 4567.
**Did NOT prove:** the meta-store migration. Prod was empty — the meta log says
`no streaming jobs for scaling, maybe an empty cluster`. dev is the only environment that will
actually exercise it.

### Gate 1 is closed

Operator v0.18.0 runs RisingWave 3.0.5. The README's compatibility table gives only minimums
and never named 3.x; this is now measured rather than inferred.

## Recommendation

**Not this week.** Reasons, in order:

1. The QA cutover is unfinished and three PRs are open. Upgrading RisingWave underneath that
   invalidates the dev proof we just completed and mixes two changes in one blast radius.
2. Gate 1 is unanswered. An operator that cannot run 3.1 makes every date wrong.
3. Nobody has yet confirmed a document landed in Atlas, so dev's pipeline is "working" on
   good evidence rather than a row count. Upgrade after that is closed, not before.

**Sequence when we do it:**

1. Answer Gate 1 — operator v0.16.0 against RisingWave v3.1 on QA2, or a scratch namespace.
   If it needs a newer operator, that is its own upgrade with its own CRD changes.
2. Audit Tim's SQL for `SOME`/`ALL`/`ANY`.
3. Meta store backup on dev, with risectl v2.8 kept beside it.
4. Bump `manifests/op-usxpress-dev/risingwave-cr.yaml` only. Watch the background migration
   complete before touching any sink.
5. Re-run `scripts/onprem-app-wireup-check.sh dev` and finish at row counts, not a green CR.
6. QA, then prod, one environment at a time.

## Proven / tested and killed / not verified

**Proven:** dev and prod both run risingwave `v2.8.2`, operator `v0.16.0`, console `v0.7.4`
(2026-10-12). v2.8 support ended 2026-10-11. v3.1.0 is current; v3.0 is supported only until
v3.2 ships.
**Tested and killed:** that a version difference explains Tim's pipeline changes — dev and
prod are the same version.
**Not verified:** QA's version (SSO expired at measurement time); whether operator v0.16.0
supports RisingWave 3.x; whether Tim's SQL uses `SOME`/`ALL`/`ANY`; the exact latest v3.1
patch; and our live frontend/ghostunnel/Gateway ports as opposed to the operator's declared
constants — the table above is read from their source, not from our cluster.

Sources: RisingWave releases and release-support-policy pages, and the risingwave-operator
README compatibility table — all read 2026-10-12.

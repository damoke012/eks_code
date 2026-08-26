# Jira drafts — 2026-08-26 (NOT POSTED)

Evidence: `scripts/rw-etl-inventory.sh`, read-only against `rw_catalog` from the running
postgres pod on each cluster. Full write-up in `FINDINGS-2026-08-18.md`.

---

## A. Comment on INFRA-1637 — reopen

> Re-read both clusters today with `rw-etl-inventory.sh` and this looks like it's still open —
> flagging rather than reopening unilaterally, in case what you completed was a different part
> of it than I'm testing.
>
> **op-dev, `risingwave` namespace, 2026-08-26:**
>
> ```
> sources: 1  -- brand_source_kafka
> plaintext credentials in source DDL: brand_source_kafka  PLAINTEXT PRESENT
> secrets defined: 15  (kafka_api_key, kafka_api_secret, kafka_bootstrap_server,
>                       kafka_schema_registry_api_key, kafka_schema_registry_api_secret, …)
> ```
>
> `rw_catalog.rw_sources.connector_props` still stores the Confluent Cloud sasl and
> schema-registry credentials as `"type": "plaintext"`. Any principal that can open a SQL
> connection and read the catalog gets working keys — no cluster access needed. The fifteen
> secrets are all present and **none of them is referenced by the source DDL**, so the secret
> layer exists and is unused.
>
> The AC has two halves and I can only see one from outside: no plaintext in any catalog table
> **on any cluster**, and the old Confluent key **revoked** rather than replaced. Can you
> confirm where each stands?
>
> **Why this got more urgent rather than less.** We confirmed today that Tim's ETL is not in QA
> — `op-qa/risingwave` probes fine and reports 0 sources, 0 materialized views, 0 sinks. The
> platform is promoted; the ETL isn't. And the reason it can't be promoted is *this ticket*:
> the topic (`dev_brand_management_cdc_brand_avro`), the group prefix
> (`dx__dev_risingwave_risingwave_dev`) and the credentials are literals inside the DDL. Our
> promotion model builds once and ships the same digest to QA and prod, so an artefact built
> from this DDL carries dev's topic and dev's keys into QA.
>
> So 1637 isn't just a credential-hygiene item any more — it's the gate on the whole RW
> promotion path. Rewriting the source to `SECRET kafka_api_key` etc. (the form in
> `FINDINGS-2026-08-18.md` §5) closes the exposure and unblocks promotion in the same change.
> One new secret is needed, `kafka_topic_brand`; everything else already exists.

---

## B. Re-scope INFRA-1644

**Current summary:** Reconcile `pipelines/Brand` against op-dev — the repo defines sinks the
live dev cluster does not run.

**Proposed summary:** Decide whether the dev ARC-runner pipeline has a purpose now that Argo CD
delivery works.

> Re-scoping this after reading both clusters' catalogs directly, because the premise was wrong
> in a way that makes the ticket **smaller**, not bigger.
>
> This was written as "two pipelines disagree, decide which is right". They don't disagree,
> because one of them isn't running anything.
>
> **op-dev, 2026-08-26:**
>
> | namespace | sources | MVs | sinks | secrets |
> |---|---|---|---|---|
> | `risingwave` (Tim's, hand-applied) | 1 | 3 | 0 | 15 |
> | `risingwave-2` (ARC runner's target) | 0 | 0 | 0 | 0 |
>
> The ARC runner `arc-runners/risingwave-pipeline` targets `risingwave-2`, and its IAM role is
> scoped to `op-usxpress-dev/risingwave-2/*` — so it cannot reach Tim's namespace by design.
> Its target namespace has no catalog objects at all. There is also **no `pipeline_applied`
> table in any database on either dev namespace**, so it has never completed a tracked run.
> Consistent with `wip/rw2-sql-cicd/STATE.md`: *"Full SQL run NOT yet executed."*
>
> So the divergence between `pipelines/Brand` and "the live dev cluster" was never a conflict
> between two live pipelines. The repo's SQL was compared against **Tim's** namespace, which the
> ARC runner does not and cannot write to.
>
> **What's actually left to decide** — a sentence from Tim or Idris closes it:
>
> 1. Does the ARC runner still have a purpose now that the Argo CD path is proven, or does it
>    get retired? It sits at min 0 / max 2 with no running pods, so it costs nothing idle and
>    there's no deadline pressure — but two delivery mechanisms is two things to maintain.
> 2. Is `pipelines/Brand` in the repo the intended target state (it defines sinks; Tim's live
>    namespace runs none), or does it need reconciling down to what's actually running?
>
> Question 2 is the one that feeds INFRA-1635 — pointing `PIPELINE_DIR` at real DDL instead of
> `smoke/` needs to know which version of the DDL is correct.

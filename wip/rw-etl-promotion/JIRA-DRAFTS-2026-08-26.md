# Jira drafts — 2026-08-26 (NOT POSTED)

Evidence: `scripts/rw-etl-inventory.sh`, read-only against `rw_catalog` from the running
postgres pod on each cluster. Full write-up in `FINDINGS-2026-08-18.md`.

---

## A. ~~Comment on INFRA-1637 — reopen~~ WITHDRAWN — replaced by A2

**Why withdrawn.** Drafted from live-cluster evidence alone, and it implied Idris had not done
the work. He had. `pipelines/Brand/100-sources.rw` on `master` carries his header:

```
08/18/2026 - Idris Fagbemi - INFRA-1637: switch all Confluent credentials to secret references.
                             Plaintext SASL/schema-registry credentials have been removed.
```

Every credential in that file is now a `secret` reference. The repo is clean.

**The lesson, and it is the same one as always:** `rw_catalog` and `git` answer different
questions. The catalog holds what the streaming job was *created with*; the repo holds what we
*intend*. A fix committed to the repo changes nothing in RisingWave until something applies it,
and nothing has. Reading only the cluster made a completed fix look like an ignored ticket.
Reading only the repo would have made a live exposure look closed. Neither source is the
answer on its own.

---

## A2. Comment on INFRA-1637 — the gap is deployment, not the fix

> Your `100-sources.rw` rewrite looks right — every credential is a `secret` reference now.
> Flagging that it hasn't reached the cluster, plus two things that I think block the cutover.
>
> **op-dev `risingwave` catalog, 2026-08-26:**
>
> ```
> sources: 1  -- brand_source_kafka
> plaintext credentials in source DDL: brand_source_kafka  PLAINTEXT PRESENT
> ```
>
> The live streaming job is still the one created from the pre-fix DDL, so the Confluent keys
> are still readable from `rw_catalog.rw_sources.connector_props` by anything that can open a
> SQL connection. The repo is fixed; the cluster hasn't been told.
>
> **1. Applying the new file will not remove the exposure.** The repo creates `kafka_brand`;
> the live source is `brand_source_kafka`. `DROP SOURCE IF EXISTS kafka_brand CASCADE` doesn't
> match it. So a clean source appears alongside the dirty one and the plaintext stays. Dropping
> `brand_source_kafka` also takes `brand_mv_raw`, `brand_mv_state` and `brand_mv_flat` with it
> via CASCADE — what's the cutover plan?
>
> **2. Who substitutes the `%VAR%` placeholders?** The file uses `'%KAFKA_TOPIC_BRAND%'`,
> `'%KAFKA_STARTUP_MODE%'` and `'%KAFKA_SCHEMA_REGISTRY_MESSAGE%'`. The Argo CD sync-hook
> applier runs `psql -f` with no substitution step that I can see, so it would send the literal
> `%KAFKA_TOPIC_BRAND%` to RisingWave. If substitution only happens on the ARC path, that's a
> blocker on INFRA-1635 and I need to add it to the applier.
>
> **3. Was the old Confluent key revoked, or replaced?** The AC asks for revoked. Separate
> question from everything above and the only one with a clock on it.

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

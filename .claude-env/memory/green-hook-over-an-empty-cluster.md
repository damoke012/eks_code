---
name: green-hook-over-an-empty-cluster
description: DISPROVEN 2026-10-16 — QA RisingWave has 2 sources, 4 MVs and 1 sink; the hypothesis that QA had never run a Brand pipeline was wrong
metadata:
  type: project
---

⛔ **This was a hypothesis and it is now FALSE.** Measured on op-usxpress-qa 2026-10-16 via
`scripts/rw-sql.sh qa`:

    SOURCES (2)   public.brand_source_kafka, public.activeresource_source_kafka
    MVs (4)       public.brand_mv_raw, public.brand_mv_state, public.brand_mv_flat,
                  public.canary_promotion_mv
    SINKS (1)     public.activeresource_sink

QA **has** run Brand and ActiveResource, and the promotion canary MV is there too. The earlier
claim — "QA's ETL reports Succeeded while RisingWave has 0 sources and 0 sinks; QA has NEVER
run a Brand pipeline" — was never measured; it was reasoned from a green hook and the
`pipeline_applied` ledger, and recorded with "(hypothesis — verify …)" attached. It survived
weeks because nothing queried the destination.

No Employee objects exist, which is correct: Employee is excluded on QA by `EXCLUDE_RE`.

**Why:** the worry was the right *shape* — a green hook genuinely cannot prove rows exist
([[adjacent-step-green-signals]]) — but the inference ran the wrong way. "A green hook does
not prove objects exist" does not license "therefore they do not." Both directions need the
query.

**How to apply:** the standing instruction stands — judge at the destination, with
`scripts/rw-sql.sh <env> "SHOW SOURCES;"`. What changes is that a *suspicion* recorded as a
finding is itself a claim, and a note that carries "(hypothesis)" has to be either measured or
dropped, not cited. See [[a-proxy-is-not-the-property]] and
[[prod-incident-instrument-check]]. The measurement costs one command and an `aws sso login`.

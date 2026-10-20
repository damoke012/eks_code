---
name: rw-version-uniform-but-eos
description: CORRECTED 2026-10-19 — the engine IS upgraded, v3.0.5 on dev/QA/prod; only dev's risingwave-2 is still v2.8.2, and the CONSOLES still display 2.8.2
metadata:
  type: project
---

Measured 2026-10-19 from each cluster's RisingWave CR (`get risingwave -A -o jsonpath=…spec.image`):

    op-dev    risingwave/risingwave    = risingwavelabs/risingwave:v3.0.5
    op-dev    risingwave-2/risingwave  = risingwavelabs/risingwave:v2.8.2   (DEV-ONLY, never promoted)
    op-qa     risingwave/risingwave    = risingwavelabs/risingwave:v3.0.5
    op-prod   risingwave/risingwave    = risingwavelabs/risingwave:v3.0.5

⛔ **This file previously said "all envs run v2.8.2".** That was true when written and stale
by the time it was being cited. The v3.0.5 upgrade happened, so the EOS exposure (v2.8 left
support 2026-10-11) applies now only to **dev's `risingwave-2`**.

Two things that remain true and are easy to conflate with the above:

- **The console still DISPLAYS v2.8.2 on QA and prod.** It records the cluster version in its
  OWN database, written only when absent, so an engine upgrade never updates it. Dev was
  corrected by `iaac-risingwave-onprem#52`; QA and prod are still stale. That is a display
  defect, not a version defect — see [[a-version-declared-twice-will-drift]]. It is part of
  INFRA-1716.
- **v3.1.x, not v3.0, was named as the target** on the 2026-10-06 call, and whether the
  operator supports engine 3.x was the unproven gate. Being on 3.0.5 does not settle that.

**Why this matters:** "version can never explain a dev-vs-prod difference" still holds for the
`risingwave` namespace — all three match. But the claim rested on a number that had changed,
and the UI agreeing with the stale number made it look confirmed. **Read `spec.image` from the
CR; never the console, and never this file's last value.**

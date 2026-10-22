---
name: promotion-order-qa2-dev-qa-prod
description: Standing rule from Doke 2026-09-17 — never break a working environment; every change proves itself in QA2 first, then dev, then QA, then prod, one environment at a time
metadata:
  type: feedback
---

**Doke, 2026-09-17:** *"we should not break any current env, and if we are changing anything
then we should first make it in Dev and ensure it works before pushing to QA, so do in QA2
first, then Dev then QA then Prod."*

The order is **QA2 → dev → QA → prod**, one environment at a time, each proving the change
before the next sees it. QA2 is the throwaway being built to absorb exactly this risk.

**Why:** dev is not a safe place to experiment — Tim's RisingWave work lives there, and a
54-day storage outage on dev went unnoticed precisely because nobody treats dev as production
for someone. QA2 is the only environment where being wrong is free.

**How to apply:**

- **Separate a change from its blast radius before proposing it.** Split work into a zero-risk
  PR (new files, dead files, inert text) and a behaviour PR (anything a `terraform plan`,
  a reconcile or a running pod would notice). The first can merge freely; the second waits for
  QA2.
- **Default every new behaviour to OFF**, enabled per environment by a flag. `TF_USE_VARFILE`
  and `enable_flux_bootstrap` are the pattern: merging changes nothing until an environment
  opts in. That is what makes "merge to master" safe in a repo where all environments share
  one branch.
- **Prove at the thing, not the tick** before promoting: the pod, the row, the catalog query.
  A green deploy is not evidence ([[octopus-green-but-no-apply]], [[adjacent-step-green-signals]]).
- **State the risk per change, not per PR.** The useful answer to "will this break anything" is
  a table with one row per change and a named failure mode, not a reassurance.

**⚠️ One repo cannot follow this rule today.** `iaac-risingwave-onprem` deploys prod from
`main` with no gate, so a merge IS a production deploy and there is no dev-then-QA-then-prod
path through it ([[rw-prod-blocked-on-manifests-path]]). Either that repo gets per-environment
gating, or the rule has a documented exception there. Raised 2026-09-17, not yet resolved.

Related: [[server-side-apply-keeps-dropped-fields]], [[onprem-deploy-via-octopus]],
[[prod-incident-instrument-check]].

---
name: tfvars-override-is-opt-in-per-env
description: "iaac-talos deploy.ps1 has TF_USE_VARFILE: when true for an environment it passes -var-file=envs/<TF_VAR_env_name>.tfvars, which OUTRANKS every Octopus TF_VAR_*. Added 2026-09-17 (c5ae7c43). Only dev/qa/qa2 tfvars exist; there is no prod.tfvars."
metadata:
  type: project
---

**The long-standing rule was: Octopus injects `TF_VAR_*` as `env.auto.tfvars` and the
`envs/*.tfvars` files in git are never read.** That was true until **2026-09-17**, commit
`c5ae7c43` *"feat(env): make envs/<env>.tfvars the source of truth, opt-in per
environment"*.

`deploy/deploy.ps1` now says it plainly:

> Terraform precedence: `TF_VAR_*` env vars are LOWER than `-var-file`. Turning this on
> makes `envs/<env>.tfvars` authoritative over every Octopus `TF_VAR_*`, so it is OPT-IN
> per environment.

**The switch is the Octopus variable `TF_USE_VARFILE`**, scoped per environment. When
true it passes `-var-file=envs/$TF_VAR_env_name.tfvars`, and it refuses to plan when
`TF_VAR_env_name` is unset rather than silently falling back to Octopus variables.

**Files present as of 2026-10-26: `dev.tfvars`, `qa.tfvars`, `qa2.tfvars`. No prod.**

**Why it matters:** every piece of reasoning about this project that starts "the tfvars in
git are not what deploys read" is now conditional on `TF_USE_VARFILE` for that
environment. An Octopus variable you set can be silently outranked by a file in git —
the opposite of the trap recorded in [[octopus-releases-freeze-variables]], and a second
source of truth for the same value ([[a-version-declared-twice-will-drift]]).

**How to apply:** before relying on any `TF_VAR_*` for an environment, check
`TF_USE_VARFILE` for that environment. The failure mode is at least loud: opted in with no
matching tfvars file, Terraform fails on the missing file instead of applying a default.

Related: [[risingwave-prod-terraform-via-octopus]], [[octopus-green-but-no-apply]].

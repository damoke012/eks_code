---
name: octopus-green-but-no-apply
description: iaac-talos Octopus deploys report Success while skipping terraform apply — TfApply is false everywhere except production
metadata: 
  node_type: memory
  type: feedback
  originSessionId: e3125f37-c991-4364-adf2-b40770a2d61c
  modified: 2026-07-29T02:50:19.708Z
---

**An iaac-talos Octopus deploy going green does NOT mean anything was applied.**

Discovered 2026-07-28 (op-usxpress-qa, AWS SSO work): five consecutive QA deploys reported **Success** in
~1 minute each and changed nothing. The step runs `terraform plan`, **prints the full diff**
(`Plan: 0 to add, 3 to change, 0 to destroy`), then skips `terraform apply` and exits 0.

Cause — project variable in the DevOps space:

```
TfApply = false   ['(all)']      <- dev, qa, dpl, staging... all inherit this
TfApply = true    ['production']
```

**Why:** the printed plan makes it *more* convincing, not less — it looks like proof the change landed.

**How to apply:** never conclude a change took effect from a green task. Grep the task log for
**`Apply complete!`**; its absence means plan-only. To actually apply on a non-prod env, add `TfApply = true`
scoped to that environment (`wip/onprem-qa-access/aws-sso-webhook/add-octopus-var.py`), then **Update
Variables** on the release — a release pins a variable snapshot and won't see a newly added project variable.

⚠️ Whether QA should stay apply-enabled is an open decision: the global `false` may have been a deliberate
safety catch added during prod standup. Leaving qa `true` makes every future QA deploy live.

Related: Octopus reads `TF_VAR_*` (env.auto.tfvars), NOT `-var-file`, so committing a value to
`deploy/terraform/envs/qa.tfvars` changes nothing at deploy time. Also open: the post-apply Flux bootstrap
step fails on an empty variable (`rm: missing operand`) — harmless while Flux is already bootstrapped, fatal
for rebuild-to-validate. See [[onprem-deploy-via-octopus]], [[onprem-human-access-model]], [[prod-standup]].


## Writing a variable: the shape Octopus requires (2026-09-01)

A `PUT /api/{space}/variables/{varsetId}` answers **HTTP 500 "Object reference not set to
an instance of an object"** if a variable object omits `Id` or `Type`. It is a null
reference in Octopus, not a permissions or payload-size problem, and the message says
nothing about the missing field.

The shape that works — used by `setup-octopus-rw.py` and `add-prod-vars.py`:

    {"Id": "", "Name": name, "Value": value, "Description": "...",
     "Scope": {"Environment": [env_id]},
     "IsEditable": True, "IsSensitive": False, "Prompt": None, "Type": "String"}

The PUT replaces the whole variable set, so a 500 leaves nothing written — but read the
set back afterwards regardless: a 200 is the write being accepted, not the values being
present.

`scripts/setup-octopus-rw-prod.py` does the read-back and refuses if `TfApply` is already
scoped to the target environment.

## QA is apply-enabled (confirmed 2026-09-10)

The open question above is answered: **`TfApply = true` is scoped to `qa`** — Idris read it
off the project during the iaac-talos #62 deploy. It was set during the July AWS SSO work and
never scoped back, so **every QA deploy applies for real**. Dev remains plan-only under the
`(all)` default.

**How to apply:** on QA, read the plan before letting a deploy run — the safety catch that
makes a dev mistake harmless is not there. Whether QA *should* stay apply-enabled is Doke's
decision and is still unmade; it is currently true by inheritance from an old task, not by
intent.

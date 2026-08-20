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

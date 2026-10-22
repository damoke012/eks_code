---
name: onprem-deploy-via-octopus
description: Constraint — iaac-talos (Dev/QA/Prod) is deployed via Octopus ONLY; never local terraform apply
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 161fed6b-7af8-49e8-9abf-c06ed6494c28
---

The on-prem Talos clusters are deployed **through Octopus Deploy only** — never `terraform apply` from a laptop/WSL.

**Why:** Octopus is the deployment control plane; it injects environment-scoped variables (secrets like vsphere_password/github_token + per-env config), runs the terraform, and gates apply. Local applies bypass that and risk drift/unauthorized change.

**How to apply:**
- A local `terraform plan` (read-only) is fine as a quick diagnostic, but the AUTHORITATIVE plan/empty-diff is the Octopus Dev deploy's plan step (it uses the real Octopus variables, avoiding local tfvars gaps).
- The multi-env refactor introduced `deploy/terraform/envs/{dev,qa}.tfvars` (committed non-secret config); secrets still come from Octopus. For Octopus to be the multi-env deploy path, its iaac-talos process must pass `-var-file=envs/<env>.tfvars` AND inject the secrets. Verifying/wiring that is core to QA completion.
- QA stand-up via Octopus = add a QA environment + QA-scoped variables (`add-qa-vars.py`) + QA backend, then deploy.

Related: [[qa-cluster-standup]].

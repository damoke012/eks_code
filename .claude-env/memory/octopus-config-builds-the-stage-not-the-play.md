---
name: octopus-config-builds-the-stage-not-the-play
description: iaac-octopus-config manages spaces/environments/worker pools/lifecycles but NO projects and NO project variables; every TF_VAR_* that builds a cluster is hand-typed
metadata:
  type: project
---

`variant-inc/iaac-octopus-config` (OpenTofu + `octopusdeploy` provider, master `9d155c8`,
2026-09-17) creates exactly five object types: `octopusdeploy_space`,
`octopusdeploy_environment`, `octopusdeploy_static_worker_pool`, `octopusdeploy_lifecycle`,
`octopusdeploy_script_module`, `octopusdeploy_library_variable_set`.

It creates **no `octopusdeploy_project` and no `octopusdeploy_variable`**.
`grep -rn "TF_VAR_\|iaac-talos" deploy/config/` returns nothing.

So the 121 `TF_VAR_*` on project `iaac-talos` — VIPs, cluster names, vSphere placement, node
sizes — are maintained by hand in a web form, in no repo, under no review.

Three traps in the module:
1. **A lifecycle phase names its environments explicitly** and resolves them via
   `local.environments[x].id`. An environment in no phase exists in the UI and can **never
   receive a deployment**. Adding it to `environments.yaml` alone gives a green PR and a dead
   environment.
2. **`sort_order = sum([index, 10])`** — list position. Insert and every later environment is
   modified. Append.
3. **`if ($SpacesVariablesTfApply -eq "true") { tofu apply }`** — same gate as `iaac-talos`'s
   `TfApply`. Green means a plan was printed. Two repos now, so it is a house convention
   ([[octopus-green-but-no-apply]]).

`allowed_spaces` is `Default` + `DevOps`; `space_vars` also lists `Engineering`, `USXpress` and
`OnPrem`, which are **not** managed here. Do not read that map as the list of managed spaces.

**A pool created here has no workers in it.** Octopus workers are pods from `variant-inc/iaac-octopus`
(Dockerfile + `configure-tentacle.sh` + Helm chart); `iaac-octopus-server` is the server. Both of
that repo's values files — the only two — set `WORKER_POOL: devops` and
`SPACES: "Default,DevOps"`, `replicaCount: 3`. So every tentacle joins one shared pool named
`devops`, and the four `usxpress-*` pools `worker_pools.yaml` creates appear to be empty. Nothing
found so far creates `devops` itself. Adding a pool for a new environment would create it empty —
clean PR, no worker at deployment time.

**Why:** this is the largest remaining hole in "everything is automated", and it is the origin
of `TBD-qa-vip`, the wrong Flux repository name in the tfvars, and dev's 2 vCPU control plane.

**How to apply:** a new environment is a PR here for the environment + worker pool + lifecycle,
and hand work for the project variables. The route out is `TF_USE_VARFILE=true` plus
`octopus/new-environment.sh`, which moves those decisions into `envs/<env>.tfvars`
([[one-account-one-cluster-assumption]], [[promotion-order-qa2-dev-qa-prod]]).

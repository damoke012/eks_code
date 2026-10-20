---
name: app-config-source-is-octopus-not-compose
description: "For a DX/Octopus-deployed app, docker-compose.yml is local dev only and the repo holds no sizing; the config inventory is Octopus project variables PLUS what DX creates in Terraform, and CPU/memory/replicas are read off the live cluster"
metadata:
  type: project
---

**2026-10-20, pricing-app onboarding call.** Idris had read the app's environment variables
out of `docker-compose.yml` and asked which were secrets. Andres: a compose file in a USX
project is *"almost always used for local development, never been used for deployment"*, and
the old ones *"may not even work correctly"*. Only the `Dockerfile` is real to the pipeline.

**Where the answers actually live:**

| Question | Source |
|---|---|
| Which variables does this app read? | **Octopus project variables**, plus whatever **DX creates in Terraform** at deploy time |
| Which are sensitive? | partly Octopus *sensitive* variables, partly AWS secrets DX built — **two inventories** |
| CPU, memory, replicas | **the running cluster.** DX generates the deployment YAML; nobody on the app team sets limits and the repo has none |

**How to apply.** Ask the app team for the **Octopus variable names** and read the **live DX
prod cluster** for sizing. Do not ask them to size the workload — for the pricing app they
did not have the answer and never did. And get DX's side from **Parul or Rohit**; the app
developers cannot describe what DX provisions for them.

⚠️ **Two true answers that disagree.** Andres: *"all of ours should be in Octopus, we don't
have anything else that's not there."* Matt, minutes earlier: *"we do have some SQL passwords
in the sensitive variables … I'm not sure if that's provisioned yet on the DX side."* Both are
honest. Enumerate both systems; never accept the first "that's all of them".

Also from Matt, and it is an argument *for* the new path: **Octopus sensitive variables can
print into a deploy log.** Secrets Manager + ESO is a genuine improvement, so say so.

Related: [[secret-and-owner-are-two-axes]], [[octopus-release-freezes-variables]],
[[octopus-all-scope-hides-inherited-values]], [[eso-does-not-reach-a-laptop]].

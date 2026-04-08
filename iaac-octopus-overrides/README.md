# iaac-octopus-overrides

Declarative on-prem overrides for the **OnPremise** Octopus space (Spaces-302).

## Why this exists

OnPremise space's DX library variable sets (DX__EKSCluster, DX__Common, DX__TFState, DX__AWSAccounts, DX__Runner) were initially cloned from USXpress space and still hold cloud values. For projects imported into OnPremise to actually deploy to the bare-metal Talos cluster (op-usxpress-dev), those library var sets need on-prem values for the `development` environment scope.

Doing this per-project (project-level variable overrides) is manual config drift. Doing it once at the library variable set layer means **every project imported into OnPremise inherits on-prem values automatically** — zero per-project rewiring.

## Cloud-safety invariants

This script is intentionally locked down so it cannot affect cloud deployments:

- **Hard refusal** if the manifest's `space.id` is not `Spaces-302` (OnPremise). USXpress space and every other space are unreachable through this tool.
- **Scope-locked** to environment `development` (Environments-1081). Existing variables scoped to qa/staging/production or unscoped are never read or written.
- **Read-only on cloud iaac**: this tool only talks to the Octopus REST API. terraform-variant-apps, mage-runner, iaac-talos, flux-platform, flux-cluster — all untouched.
- **Idempotent**: re-runs are no-ops if the manifest matches current state.

## Usage

```bash
export OCTOPUS_API_KEY=API-XXXXXXXXXX
pip install pyyaml   # one-time
./apply.py onprem-development.yaml --dry-run   # preview
./apply.py onprem-development.yaml             # apply
```

## What's in the manifest

`onprem-development.yaml` declares the on-prem values for variables that route MageRunner to op-usxpress-dev:

| Library var set | Variable | On-prem value | Why |
|---|---|---|---|
| DX__EKSCluster | CLUSTER_NAME | `op-usxpress-dev` | Used by terraform-variant-apps eks-data SSM lookup |
| DX__EKSCluster | CLUSTER_REGION | `us-east-1` | SSM mirror region (canonical us-east-2 was mirrored to us-east-1 by iaac-talos commit 07d4955) |
| DX__Common | WORKER_POOL | `onprem-development` (resolved to WorkerPools-1922) | Octopus deployment target |
| DX__Common | env_short / environment_abbreviation | `dev` | matches MageRunner env gate |
| DX__TFState | S3_BUCKET | `dpl2-local-test-tfstate` | terraform state bucket in Playground us-east-1 |
| DX__TFState | DYNAMO_DB_TABLE | `""` | no locking on-prem (matches local test pattern) |
| DX__AWSAccounts | AWS_ACCOUNT_dev | `786352483360` (Playground) | overrides cloud dev account |
| DX__AWSAccounts | AWS_REGION_dev | `us-east-1` | matches state bucket region |
| DX__Runner | TF_VAR_use_eks_api | `false` | gates eks-data module to SSM fallback path |
| DX__Runner | TF_VAR_cluster_name | `op-usxpress-dev` | passed via TF_VAR_* convention by mage-runner |

## How "if SSM is routing to on-prem the override happens" works

1. Octopus runs the imported project's `DX-Apply` script step in OnPremise space, environment=development.
2. Octopus injects all the library variable set values (env=development scope) as env vars to the script.
3. Script runs MageRunner. MageRunner reads `TF_VAR_*` env vars and writes them into `env.auto.tfvars` per terraform module dir (`mage-runner/internal/terraform/terraform_helpers.go:getTfVarsFromEnv`).
4. terraform-variant-apps' `eks-data` module sees `var.use_eks_api = false` → switches to SSM read path (per INFRA-1446 commit `feature/onprem-support` 6715ce1+6e9d305).
5. SSM read at `/clusters/op-usxpress-dev/{endpoint,certificate_authority,oidc_issuer,token}` (us-east-1 mirror, mirrored by iaac-talos commit 07d4955) → returns Talos API endpoint + cluster_token.
6. Terraform `kubernetes` and `helm` providers authenticate via the cluster_token + Talos endpoint → apply lands on op-usxpress-dev.

The library variable set is the trigger. SSM is the routing. eks-data is the bridge.

## Future migration

When **iaac-octopus-config** lands (INFRA backlog ONPREM-10), port this manifest to terraform `octopusdeploy_library_variable_set_variable` resources. The yaml + python here is a stop-gap that captures the desired state declaratively in the meantime.

## CI/CD wiring (future)

A GHA workflow can run `./apply.py onprem-development.yaml --dry-run` on PR and `./apply.py` on merge to main. The OCTOPUS_API_KEY would come from a repo secret. Until that's wired, run manually.

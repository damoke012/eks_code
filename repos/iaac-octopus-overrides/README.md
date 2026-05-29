# Octopus automation for OnPremise space

Lives in `iaac-talos/octopus/` — all the Octopus API-driven setup and per-app
wiring for the `op-usxpress-dev` on-prem cluster.

## Why this exists

MageRunner deployments go through the **OnPremise** Octopus space (Spaces-302).
That space needs configuration that's different from cloud USXpress space —
overridden variables, patched deployment processes, seeded terraform state.

Rather than configure each piece manually via the Octopus UI (which drifts),
everything is codified here and applied via GHA on merge.

## What lives in this directory

### Manifests
- `onprem-development.yaml` — library variable set overrides (dev scope only)
  - DX__EKSCluster, DX__Common, DX__TFState, DX__AWSAccounts, DX__Runner, DX__AWSAccessKeys

### Scripts (idempotent, run by GHA)
| Script | What it does | When it runs |
|---|---|---|
| `apply.py` | Applies `onprem-development.yaml` to Octopus | On merge to main |
| `patch-setup-variables.py` | Patches DX__SetupVariables ScriptModule (simplifies SSM block) | On merge to main |
| `patch-dx-apply.py` | Patches DX-Apply deployment process (adds SSM kubeconfig block) | On merge to main |
| `mirror-release.py` | Mirrors latest cloud releases to OnPremise space | Every 15 min (cron) |
| `onboard-app.py` | Per-app: seeds tf state, syncs secrets, copies project vars | Manual trigger when adding an app |

### GHA workflows (at `iaac-talos/.github/workflows/`)
| Workflow | Trigger | Runs |
|---|---|---|
| `onprem-setup.yaml` | Push to main (octopus/ path) | apply.py + patch-*.py |
| `mirror-releases.yaml` | Schedule (15 min) | mirror-release.py --all |
| `onboard-app.yaml` | Manual | onboard-app.py --app X |

## Cloud-safety invariants

All scripts are locked down to prevent affecting cloud deployments:

- **Hard refusal** if the manifest's `space.id` is not `Spaces-302` (OnPremise). USXpress space and every other space are unreachable.
- **Scope-locked** to environment `development` (Environments-1081). Existing qa/staging/production scopes never read or written.
- **Read-only on cloud**: Cloud terraform state bucket and Secrets Manager are read once per onboarding (for state seeding), never written to.
- **Idempotent**: every script is safe to re-run.

## Cluster rebuild flow

After a teardown+rebuild of op-usxpress-dev:

1. **iaac-talos terraform** → cluster + SSM + worker IAM policies (via terraform pipeline)
2. **iaac-talos-flux-platform** → ESO 2.2.x, namespaces, ClusterSecretStore (Flux reconciles from git)
3. **This workflow (`onprem-setup`)** → variable overrides + module/script patches (GHA on merge)
4. **For each app: `onboard-app`** → state seeding, secret sync, project vars (manual trigger)
5. **Deploy** → via Octopus UI (mirror-release creates releases, deployment is manual per feature-manual lifecycle)

## Usage (manual, during development)

```bash
export OCTOPUS_API_KEY=API-XXXXXXXXXX
pip install pyyaml

# Apply variable overrides
./apply.py onprem-development.yaml --dry-run   # preview
./apply.py onprem-development.yaml             # apply

# Patch Octopus scripts
./patch-setup-variables.py
./patch-dx-apply.py --all

# Onboard a new app (after Bento import)
./onboard-app.py brands-api
./patch-dx-apply.py --project brands-api
```

## What's in the variable manifest

| Library var set | Variable | On-prem value | Why |
|---|---|---|---|
| DX__EKSCluster | CLUSTER_NAME | `op-usxpress-dev` | Used by terraform-variant-apps eks-data SSM lookup |
| DX__EKSCluster | CLUSTER_REGION | `us-east-1` | SSM mirror region (mirrored by iaac-talos commit 07d4955) |
| DX__Common | WORKER_POOL | `onprem-development` (resolved to WorkerPools-1922) | Octopus deployment target |
| DX__Common | env_short / environment_abbreviation | `dev` | matches MageRunner env gate |
| DX__TFState | S3_BUCKET | `dpl2-local-test-tfstate` | terraform state bucket in Playground us-east-1 |
| DX__TFState | DYNAMO_DB_TABLE | `""` | no locking on-prem (matches local test pattern) |
| DX__AWSAccounts | AWS_ACCOUNT_dev | `786352483360` (Playground) | overrides cloud dev account |
| DX__AWSAccounts | AWS_REGION_dev | `us-east-1` | matches state bucket region |
| DX__AWSAccessKeys | AWS_ROLE_TO_ASSUME | worker's own role ARN | on-prem uses IRSA; no cross-account chaining |
| DX__AWSAccessKeys | AWS_DEFAULT_REGION | `us-east-1` | matches playground SSM/S3/SM region |
| DX__Runner | TF_VAR_use_eks_api | `false` | gates eks-data module to SSM fallback path |
| DX__Runner | TF_VAR_cluster_name | `op-usxpress-dev` | passed via TF_VAR_* convention by mage-runner |

## How routing to on-prem works

1. Octopus runs DX-Apply for project in OnPremise space, env=development
2. Octopus injects library variable set values (env=development scope) as env vars
3. DX-Apply inline script (patched) reads SSM for cluster endpoint/CA/token → writes kubeconfig
4. MageRunner runs, reads `TF_VAR_*` env vars, writes `env.auto.tfvars` per module
5. terraform-variant-apps' `eks-data` module sees `use_eks_api = false` → switches to SSM read path
6. SSM returns Talos API endpoint + token → terraform providers authenticate → apply lands on op-usxpress-dev

The library variable set is the trigger. SSM is the routing. eks-data is the bridge.

## Future migration

When `iaac-octopus-config` terraform lands (INFRA backlog ONPREM-10), port `onprem-development.yaml` to terraform `octopusdeploy_library_variable_set_variable` resources. The yaml+python here is a stop-gap capturing desired state declaratively until then.

# Session 2 — Octopus (config + onprem + overrides)

**Duration:** 90 min
**Goal:** Idris can navigate the OnPremise Octopus space, explain the spaces model, run the onboard-app and mirror-release workflows, and modify `onprem-development.yaml` to add a variable.
**Format:** Live Octopus UI walk + code walk + GHA dispatch.

---

## Why this session is here

iaac-talos (Session 1) gave us a cluster. Now we need to actually deploy to it. Octopus is the deployment platform. This session covers (a) the spaces model, (b) why on-prem has its own space, (c) the automation we built to manage it.

---

## Prerequisites

- Octopus access to USXpress (Spaces-245) and OnPremise (Spaces-302) spaces.
- Cloned `iaac-octopus-overrides` (or `iaac-octopus-onprem` if it's been renamed by then).
- AWS access to USX-Dev (700736442855).

---

## Agenda (90 min)

| Time | Topic |
|------|-------|
| 0–5 | Recap |
| 5–15 | Octopus concepts: spaces, projects, environments, channels, lifecycles, library variable sets, worker pools |
| 15–25 | The two-spaces model: USXpress vs OnPremise |
| 25–35 | iaac-octopus-config (cloud, hands-off) + history of PR #89 |
| 35–60 | iaac-octopus-overrides repo deep dive — every script + workflow |
| 60–70 | The override YAML model: how `onprem-development.yaml` becomes Octopus variables |
| 70–80 | Release-mirror workflow: how cloud releases land on OnPremise |
| 80–90 | Hands-on: dispatch onboard-app workflow + Q&A |

---

## Section 1 — Octopus concepts (10 min)

If Idris has used Octopus before, skim. If not, drill.

| Concept | Definition | Example |
|---|---|---|
| **Space** | Top-level tenant boundary. No data crosses spaces. | USXpress (Spaces-245), OnPremise (Spaces-302) |
| **Project** | A deployable thing. One project = one app. | brands-api, geo-handler |
| **Environment** | A target. Names like development, qa, production. | development, dev, qa, prod |
| **Channel** | A release lane. Different lifecycles or version gates. | main, feature, feature-manual |
| **Lifecycle** | Defines which environments a release can progress through, in order. | Release: dev→qa→prod. Feature: dev only. |
| **Library Variable Set** | Reusable variable bundle scoped per env. Shared across projects. | DX__Common, DX__EKSCluster, DX__TFState |
| **Worker Pool** | Group of "workers" (machines) that run deployment steps. | onprem-development (runs on op-usxpress-dev cluster) |
| **Release** | A snapshot of project + variables + packages, ready to deploy. | brands-api 1.1266 |
| **Deployment** | A release applied to an environment. | brands-api 1.1266 to dev |

---

## Section 2 — The two-spaces model (10 min)

### USXpress (Spaces-245) — cloud
- Owned by **cloud team** via `iaac-octopus-config` repo.
- Projects deploy to **EKS clusters** (usx-dev, qa-one, usxpress-prod).
- Library variable sets assume EKS data sources work.
- ~150 projects, all production.

### OnPremise (Spaces-302) — on-prem
- Owned by **us** via `iaac-octopus-overrides` (→ `iaac-octopus-onprem`).
- Projects deploy to **op-usxpress-dev Talos** cluster.
- Library variable sets override the cloud assumptions (CLUSTER_NAME, S3_BUCKET, TF_VAR_use_eks_api).
- Currently 4 projects (brands-api, geo-handler, io-notifications-handler, attrition-api).

### Why two spaces, not two environments in one space?

Vibin made this call. Reasoning:
- **Blast radius**: a bad on-prem variable can't accidentally affect cloud deployments.
- **Lifecycle isolation**: on-prem uses `feature-manual` lifecycle (no auto-progression). Cloud uses standard release lifecycle.
- **Permissions**: on-prem team gets full admin in OnPremise; read-only in USXpress.
- **Worker pools**: on-prem worker pool is wired into OnPremise space only.

### How releases flow between spaces

Cloud creates a release in USXpress when GHA + mage-runner runs. Our **mirror-release workflow** copies that release into OnPremise, replacing cloud-pinned packages (mage-runner, terraform-variant-apps) with on-prem fork versions.

Diagram:

```
GHA (app repo CI)
   ↓
mage-runner (cloud config)
   ↓
Octopus USXpress space — release N created (e.g., brands-api 1.1266)
   ↓
[mirror-release.py runs every 15min, or on fork-publish event]
   ↓
Octopus OnPremise space — release N created with packages overridden:
   - mage-runner: feature-onprem-support tag instead of main
   - terraform-variant-apps: feature-onprem-support tag instead of main
   ↓
[Human clicks Deploy in Octopus UI — feature-manual lifecycle requires manual]
   ↓
Octopus worker (in onprem-development pool) executes deployment
```

---

## Section 3 — iaac-octopus-config + PR #89 history (10 min)

### What it is

`iaac-octopus-config` is the cloud-team-owned repo that defines library variable sets, projects, lifecycles, channels for the USXpress space. JSON-driven; pushed via Octopus API in CI.

### Why we don't put on-prem here

We tried. PR #89 added on-prem variable sets. Vibin closed it on 2026-04-23 with feedback: **"on-prem doesn't belong in the cloud config repo. Make a separate repo."**

Result: we created `iaac-octopus-onprem` (or kept building in `iaac-octopus-overrides` — names are converging). All on-prem Octopus work goes there.

See [memory: onprem_iaac_octopus_config_repo.md] and [memory: onprem_release_mirror_pr89.md].

**Rule for Idris:** never push to iaac-octopus-config. If we need to know what cloud has there, read; don't write.

---

## Section 4 — iaac-octopus-overrides repo deep dive (25 min)

### Layout

```
iaac-octopus-overrides/
├── .github/workflows/
│   ├── onprem-setup.yaml              # Apply all overrides on push to main
│   ├── onboard-app.yaml               # Per-app onboarding (manual dispatch)
│   ├── onprem-account-bootstrap.yaml  # Attach iaac-talos-bootstrap policy
│   ├── mirror-releases.yaml           # Cron every 15 min — mirror cloud → on-prem
│   ├── remirror-on-fork-push.yaml     # Event-driven on fork package publish
│   └── apply-cloud-rbac.yaml          # Maintain cross-cluster ESO RBAC on cloud EKS
├── apply.py                           # Upserts library variables to OnPremise
├── onboard-app.py                     # One-time per-app setup (state, secrets, vars)
├── mirror-release.py                  # Mirror cloud release → on-prem with package overrides
├── patch-dx-apply.py                  # Patches DX-Apply script to add SSM kubeconfig + spec.yaml strip
├── patch-setup-variables.py           # Patches DX__SetupVariables to defer SSM to DX-Apply
├── apply-bootstrap-perms.sh           # Attach iaac-talos-bootstrap inline policy
├── apply-worker-iam-policies.sh       # Attach worker SSM/ECR/S3/SM policies
├── onprem-development.yaml            # Manifest of library variable values
├── onprem-enrolled-apps.yaml          # Apps enrolled for mirroring
├── terraform/
│   └── worker-iam-policies.tf         # TF version of apply-worker-iam-policies.sh
├── cross-cluster-eso/
│   ├── cloud-rbac/                    # SAs/RoleBindings applied to cloud EKS
│   ├── cluster-secret-store/          # On-prem ClusterSecretStore for cloud-eks provider
│   ├── app-secrets/                   # ExternalSecrets that source from cloud
│   ├── apply-cloud-rbac.sh
│   └── bootstrap-onprem-token.sh
├── README.md
├── flux-platform-changes.md
└── flux-manifest-brands-api-app-secret.md
```

### apply.py — the override applier

**Path:** `apply.py`
**Purpose:** Reads `onprem-development.yaml`, upserts library variables in OnPremise space.

**Key functions:**
- `api(method, path, body, key)` — generic Octopus API caller. URL: `https://octopus.example.com/api/Spaces-302/<path>`. Auth header: `X-Octopus-ApiKey`.
- Resolves `target_environment` name → ID (e.g., `development` → `Environments-1081`).
- Resolves `target_worker_pool` name → ID.
- For each library variable set in the manifest:
  - Fetches existing variables.
  - Diffs against manifest values.
  - PUTs updated variable list back.

**Key safety check:**
```python
if manifest['space']['id'] != 'Spaces-302':
    sys.exit("Refusing to apply: space ID is not OnPremise (Spaces-302)")
```
This is the cloud-safety guarantee — apply.py *cannot* hit the cloud space even if you point it there.

**Inputs:**
- `OCTOPUS_API_KEY` env var.
- Positional arg: manifest file path.
- `--dry-run` flag.

**Idempotent.** Running it twice changes nothing (only diffs are written).

### onboard-app.py — per-app onboarding

**Purpose:** Multi-step setup for a new app on OnPremise. Run once per app.

**Steps:**
1. **Seed terraform state** — copy `common/auth` and `common/mongodb-user` state from cloud S3 to on-prem S3. (Post-2026-04-21, accounts are unified, so this is usually a no-op — but the script keeps the capability for the multi-account scenario.)
2. **Reconcile SM ARN references** — when state was created in cloud account, ARN account IDs may need rewriting. No-op today.
3. **Copy MongoDB Atlas cert secrets** — only if cloud and on-prem are different AWS accounts. No-op today.
4. **Copy missing project variables** — for the named project, fetch USXpress project vars, write missing ones to OnPremise project.
5. **Delegate to patch-dx-apply.py** — inject the on-prem preflight block in the project's deployment process.

**Inputs:**
- `OCTOPUS_API_KEY`
- App name (e.g., `brands-api`) or `--all` for the 6 POC apps.
- AWS credentials (assumed via OIDC in GHA).

**GHA workflow:** `onboard-app.yaml`. Manual dispatch with `app_name` + `dry_run` + `all_apps` inputs.

### mirror-release.py — release mirroring

**Purpose:** Copy cloud releases to OnPremise with on-prem package overrides.

**Algorithm:**
1. Read `onprem-enrolled-apps.yaml` → list of app names.
2. For each app:
   a. Find project in USXpress (Spaces-245) by name.
   b. Find project in OnPremise (Spaces-302) by name.
   c. Get latest USXpress release.
   d. Check if version exists in OnPremise; skip if so.
   e. Resolve OnPremise channel ID (`feature-manual`).
   f. For each `SelectedPackage` in cloud release:
      - If package is `mage-runner` or `terraform-variant-apps`, query OnPremise feed for latest matching `feature-onprem-support` tagged version.
      - Replace the version in the package list.
   g. POST a new release to OnPremise with the modified package list.

**Important:** does NOT deploy. OnPremise uses `feature-manual` lifecycle so a human must click Deploy.

**Triggers:**
- `mirror-releases.yaml` — cron `*/15 * * * *`.
- `remirror-on-fork-push.yaml` — repository_dispatch from fork CI when fork package published.

### patch-dx-apply.py — the on-prem preflight script injection

**Purpose:** Patches the DX-Apply step in each OnPremise project's deployment process. Adds an "on-prem preflight" PowerShell block.

**What the preflight block does:**
1. Check `TF_VAR_use_eks_api` env var.
2. If `false` (on-prem path):
   a. Read SSM parameters at `/clusters/op-usxpress-dev/{endpoint, ca, token}`.
   b. Write a kubeconfig file for kubectl/helm/terraform.
   c. Log into ECR (cross-account, since image is in 064859874041).
   d. Strip `infrastructure.auth` from `spec.yaml` (we reference, don't duplicate).
   e. Keep `infrastructure.mongodb` (needed for on-prem configmap wiring with v2 fork).

**Why on-prem strips `infrastructure.auth`:** mage-runner would otherwise try to create an Azure AD app, but we want to *reference* the cloud-created one via ExternalSecret. Stripping it skips the auth submodule entirely.

**Re-runnable.** The block is bracketed by `# === BEGIN onprem-preflight ... ===` markers. Each run replaces the entire block, so policy tweaks propagate.

### patch-setup-variables.py — minor companion

**Purpose:** Patches the `DX__SetupVariables` library variable set's `SetAWSCredentials` PowerShell function. Removes the SSM kubeconfig fetch (which used to be there) and replaces it with a "deferred to DX-Apply" message.

**Why:** the SetupVariables module runs under the *deployment cross-account role*, which doesn't have on-prem SSM read permissions. The SSM logic moved to DX-Apply, which runs under IRSA on the on-prem worker.

### apply-bootstrap-perms.sh — bootstrap permissions

**Purpose:** Attach `iaac-talos-bootstrap` inline policy to the `octopus-usxpress` IAM role in the target AWS account.

**Why needed:** Bootstrapping a new on-prem cluster requires CloudFront + IAM OIDC provider permissions that aren't in the standard role. This script adds them once per AWS account.

**Granted permissions** (scope-limited to the cluster name as a prefix):
- CloudFront OAC + Distribution lifecycle
- IAM OpenID Connect Provider lifecycle
- IAM Role lifecycle (with policy attach/detach) on `op-usxpress-{env}-*` resources

**Triggered by:** `onprem-account-bootstrap.yaml` workflow with target_env (dev/qa/prod) + cluster_name + dry_run inputs.

See [memory: onprem_account_bootstrap_pattern.md].

### apply-worker-iam-policies.sh

**Purpose:** Attach 4 inline policies to `iaac-octopus-worker-op-usxpress-dev` role.

**Policies:**
1. **ssm-cluster-params-read** — `ssm:GetParameter` on `/clusters/op-usxpress-dev/*`.
2. **ecr-login** — ECR auth + describe (cross-account to 064859874041).
3. **s3-tfstate** — S3 CRUD on `op-usxpress-dev-tfstate`.
4. **secretsmanager-rw** — SM full CRUD (for app-secrets, auth, ESO).

There's also a Terraform version (`terraform/worker-iam-policies.tf`) — same policies, declarative. Currently the shell script is the one we run; the TF is aspirational.

### cross-cluster-eso/

The POC bridge that pulls cloud-cluster k8s secrets onto the on-prem cluster.

**Why it exists:** The Mongo Atlas user TF module writes the X.509 cert *to a Kubernetes Secret*, not to AWS SM. So we can't just point ESO at SM — we have to read it from the cloud cluster's k8s API.

**Files:**
- `cloud-rbac/onprem-reader-geoservices.yaml` — SA + Role + RoleBinding on cloud EKS, scoped to one namespace, get/list/watch on secrets only.
- `cluster-secret-store/cloud-eks.yaml` — on-prem ClusterSecretStore using `kubernetes` provider, bearer token from cloud SA.
- `app-secrets/geoenrichment-sync-handler.yaml` — ExternalSecret using the cloud-eks store.
- `apply-cloud-rbac.sh` — script to apply the cloud-side RBAC. Run by `apply-cloud-rbac.yaml` GHA workflow under cloud OIDC.
- `bootstrap-onprem-token.sh` — one-time setup to create the bearer token secret on-prem.

**SPOF flag**: this depends on the cloud cluster's k8s API being reachable. If cloud goes down, on-prem can't refresh secrets (existing ones cached, but rotation breaks). Migration path: get the cert into AWS SM and use the default ClusterSecretStore. See [memory: onprem_prod_readiness_cross_cluster_eso_spof.md].

---

## Section 5 — The override YAML model (10 min)

### onprem-development.yaml — schema

```yaml
space:
  id: Spaces-302               # Hard-coded; if not this, apply.py refuses
  name: OnPremise

target_environment: development     # Resolves to Environments-1081
target_worker_pool: onprem-development
target_cluster: op-usxpress-dev

library_variable_sets:
  <LVS_NAME>:
    variables:
      <VAR_NAME>: <value>
```

### Real example — what's actually in there

```yaml
library_variable_sets:
  DX__EKSCluster:
    variables:
      CLUSTER_NAME:    op-usxpress-dev
      CLUSTER_REGION:  us-east-2

  DX__Common:
    variables:
      WORKER_POOL:               onprem-development
      env_short:                 dev
      environment_abbreviation:  dev

  DX__TFState:
    variables:
      S3_BUCKET:        op-usxpress-dev-tfstate
      DYNAMO_DB_TABLE:  ""

  DX__AWSAccounts:
    variables:
      AWS_ACCOUNT_dev:  "700736442855"
      AWS_REGION_dev:   us-east-2

  DX__Runner:
    variables:
      TF_VAR_use_eks_api:   "false"
      TF_VAR_cluster_name:  op-usxpress-dev

  DX__AWSAccessKeys:
    variables:
      AWS_ROLE_TO_ASSUME:  arn:aws:iam::700736442855:role/iaac-octopus-worker-op-usxpress-dev
      AWS_DEFAULT_REGION:  us-east-2
      DOMAIN:              dev.usxpress.io
```

### Mapping YAML → Octopus

- Top-level keys under `library_variable_sets` are **library variable set names** (must already exist in the OnPremise space).
- Each `variables` entry is upserted with `Scope.Environment = [Environments-1081]` (development env only).
- `apply.py` does the API calls — it's not a TF apply.

### onprem-enrolled-apps.yaml — schema

```yaml
apps:
  - name: brands-api
    kind: api
    notes: "First POC, end-to-end proven"
  - name: geoenrichment-sync-handler
    kind: handler-mongo-atlas
    notes: "Mongo-atlas v2 pattern proven"
```

`mirror-release.py` reads this list and mirrors each app's latest cloud release.

### Hands-on (5 min)

Have Idris add a new variable to `onprem-development.yaml`:

```yaml
DX__Common:
  variables:
    NEW_VAR_FOR_TEST: "hello-from-idris"
```

Run `./apply.py onprem-development.yaml --dry-run`. Observe the diff. Don't actually apply (he doesn't have prod creds yet).

---

## Section 6 — Hands-on: dispatch onboard-app workflow (10 min)

This will be his first actual click-to-deploy moment.

### What we'll do
- Pick a new app to onboard. Recommend: `safetylytx-video-api` or another from `onprem-enrolled-apps.yaml` that's not yet onboarded.
- Walk him through `gh workflow run onboard-app.yaml -f app_name=<app> -f dry_run=true`.
- Show the GHA logs streaming.
- Read the dry-run output: what state would be seeded, what variables would be copied.
- Discuss what changes if `dry_run=false`.

### Don't actually do the live onboarding

Save that for next session when he's had time to absorb. Or do it in office hours with him driving and Dare watching.

---

## Common pitfalls

- **"My variable change didn't take effect."** Did `apply.py` actually run? GHA on push to main, OR manual dispatch. Variable cache also lives in deployment process snapshot — may need a fresh release.
- **"Mirror-release didn't pick up my fork change."** Octopus feed must index the new package version. Wait 60s after CI publishes. The `remirror-on-fork-push.yaml` builds in a `sleep 60`.
- **"Why did patch-dx-apply touch all my projects?"** It does. `--all` is the safe default after merging changes to `apply.py` or the preflight block. Idempotent.
- **"My DX-Apply step says 'kubeconfig deferred'."** Then SetupVariables is patched correctly. The actual SSM read happens in DX-Apply.
- **"Mirror-release skipped my project."** It's not in `onprem-enrolled-apps.yaml`. Add it.
- **"Mirror created the release but no override packages."** The fork hasn't published a `feature-onprem-support` tag yet. Push to fork branch and let CI publish.

---

## Cloud-safety guarantees (drill these)

- `apply.py` checks `space.id == Spaces-302` and exits if not.
- `mirror-release.py` only writes to OnPremise; reads cloud.
- `patch-dx-apply.py` only writes to OnPremise.
- `apply-cloud-rbac.yaml` is the *only* script that writes to cloud, and it requires manual `apply` mode (push events default to dry-run).
- Bootstrap policy is scope-limited to `op-usxpress-{env}-*` resources.

If Idris ever finds a script that writes to cloud without these guards, flag it.

---

## Homework before Session 3

1. Onboard one new app live (during office hours with Dare). Document the steps.
2. Read [memory: onprem_octopus_onprem_repo.md] and [memory: onprem_iaac_octopus_config_repo.md] for the historical context.
3. In Octopus UI, click into brands-api → Deployment Process → DX-Apply step. Read the patched script. Find the BEGIN/END markers. Read the SSM block.
4. One question for Session 3.

---

## Reference cheat sheet

| Thing | Value |
|---|---|
| OnPremise space ID | Spaces-302 |
| USXpress space ID | Spaces-245 |
| Development env ID | Environments-1081 |
| Worker pool | onprem-development |
| Worker IAM role | `arn:aws:iam::700736442855:role/iaac-octopus-worker-op-usxpress-dev` |
| Bootstrap role | `octopus-usxpress` |
| Mirror cron | `*/15 * * * *` |
| Mirror enrolled apps | `onprem-enrolled-apps.yaml` |
| Override manifest | `onprem-development.yaml` |
| Cloud-safety check | `space.id == Spaces-302` in apply.py |

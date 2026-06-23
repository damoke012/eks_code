# iaac-octopus-onprem — Octopus Deploy IaC for On-Prem Clusters (target pattern)

> **Status (2026-06-23):** REPO EXISTS. OnPremise space stand-up is **BLOCKED on Octopus admin token** (Doke does not hold it). This README documents the **target** pattern so the moment the token arrives, the bootstrap runbook can execute without rediscovery. Tracking: **INFRA-1535** (space + bootstrap), **INFRA-1543** (worker pool IaC), **INFRA-1544** (marathon umbrella).

---

## Purpose

`variant-inc/iaac-octopus-onprem` houses the Terraform that defines the **OnPremise Octopus Deploy space**, the **on-prem worker pool**, and the **project bindings** that drive `terraform apply` for every on-prem cluster repo (iaac-talos, iaac-risingwave-2, iaac-cross-cluster-eso, future on-prem TF repos). It is the IaC peer to the Cloud Octopus space: same provider, same TfApply ceremony, separate workers because the on-prem cluster is VPN-protected and the cloud worker pool cannot reach it.

This repo does **not** hold cluster manifests (those live in `iaac-talos-flux-cluster` and `iaac-talos-flux-platform`, consumed via Flux), and it does **not** hold app deployment definitions. It holds **only the Octopus topology** for on-prem TF execution and the **bootstrap-only** Octopus runbook that seeds cross-cluster secrets (cloud-eks ESO reader token, etc.).

---

## Current state

| Item | State | Notes |
|---|---|---|
| Repo created in `variant-inc` org | DONE | Empty shell — no TF yet |
| OnPremise Octopus space | **BLOCKED** | Needs admin token (INFRA-1535) |
| On-prem worker pool registration | **BLOCKED** | Needs space first (INFRA-1543) |
| Project bindings (iaac-talos, rw-2, x-cluster-eso) | **BLOCKED** | Needs space + pool |
| Bootstrap runbook (seed cloud-eks ESO token) | DESIGNED, not implemented | Documented in §7 below |
| Cloud Octopus space (reference) | OPERATIONAL | Used as template for OnPremise space |
| iaac-talos cluster TF (driven by this space) | OPERATIONAL via local apply | Will migrate to Octopus once space exists |

**This README is the 2026-06-23 closeout artifact.** No PRs landed in this repo this marathon session — every other piece of the on-prem TfApply ceremony was unblocked except this one. Once the admin token is in hand, §7 is the first PR.

---

## Architecture (target)

```
                 +-----------------------------+
                 |  Octopus Deploy (SaaS)      |
                 |                             |
                 |  +-----------------------+  |
                 |  |  Cloud space          |  |  <-- existing, drives cloud iaac-talos / iaac-eks
                 |  |  - cloud worker pool  |  |
                 |  +-----------------------+  |
                 |                             |
                 |  +-----------------------+  |
                 |  |  OnPremise space      |  |  <-- THIS REPO defines it
                 |  |  - on-prem worker pool|  |
                 |  |  - projects:          |  |
                 |  |     iaac-talos        |  |
                 |  |     iaac-risingwave-2 |  |
                 |  |     iaac-x-cluster-eso|  |
                 |  +-----------+-----------+  |
                 +--------------|--------------+
                                |
                                v  TfApply runs land on:
                 +-----------------------------+
                 |  on-prem worker(s)          |
                 |  (inside corp VPN)          |
                 |  - kubectl/talosctl reach   |
                 |    op-usxpress-dev API VIP  |
                 |    10.10.82.50:6443         |
                 +-----------------------------+
```

Components defined by this repo:

- **OnPremise space** — `octopusdeploy_space` resource. Owners: Cloud Platform Team. No PII, no app-level deployment targets — TF-only space.
- **Worker pool** — `octopusdeploy_worker_pool` + `octopusdeploy_listening_tentacle_worker` resources. Workers run on dedicated on-prem hosts (NOT on Talos CP nodes — keeps Octopus tentacle off the cluster control plane).
- **Project bindings** — one `octopusdeploy_project` per on-prem TF repo. Each project pulls VCS from its repo, exposes the `TfApply` variable, and runs against the on-prem worker pool.
- **Cross-cluster ESO source binding** — bootstrap-only runbook that mints the `cloud-eks` reader token used by on-prem External Secrets to read from cloud AWS Secrets Manager. See `onprem_cross_cluster_eso_pattern` and `onprem_cluster_secrets_pattern`.

---

## Why a separate on-prem Octopus space

Three reasons, in priority order:

1. **Network reachability.** Cloud Octopus workers live in AWS and cannot reach the on-prem Talos API VIP `10.10.82.50:6443` — it is VPN-gated. TF runs that need `kubectl`, `talosctl`, or direct API access must execute on a worker physically inside the on-prem network.
2. **Blast-radius isolation.** A misfire on a cloud-space project should not be able to target an on-prem cluster. Separate space = separate variable sets = separate Octopus RBAC = separate worker pools. A cloud TfApply cannot accidentally `terraform destroy` against on-prem.
3. **Credential locality.** On-prem TF needs the on-prem `talosconfig`, the on-prem kubeconfig, and the on-prem cluster CA. These live on the on-prem worker — they never traverse to the cloud space's variable store.

---

## TfApply ceremony

Every project in the OnPremise space exposes a single `TfApply` boolean variable. The rule is identical to the Cloud space and to `iaac-talos`:

```
default state:    TfApply = false
to apply change:  1. open PR, merge to project's tracked branch
                  2. flip TfApply = true in Octopus UI (or via variable set update)
                  3. run the project release
                  4. wait for green
                  5. flip TfApply = false
                  6. DONE
```

**Never leave `TfApply = true`.** A stuck `true` means the next merge or re-release auto-applies, which has caused incidents in the cloud space. The ceremony exists to make every apply a deliberate human action.

Reference: same pattern as `variant-inc/iaac-talos` (cloud) — see that repo's README for the historical rationale.

---

## Bootstrap runbook (target — runs ONCE per environment)

Pre-req: Octopus admin token in hand. Without it, every step below 404s.

### 7.1 Create OnPremise space

```hcl
# terraform/space.tf
terraform {
  required_providers {
    octopusdeploy = {
      source  = "OctopusDeployLabs/octopusdeploy"
      version = "~> 0.21"
    }
  }
}

provider "octopusdeploy" {
  address = var.octopus_address  # https://knight-swift.octopus.app
  api_key = var.octopus_admin_api_key
  # space_id intentionally omitted at root — we create the space here.
}

resource "octopusdeploy_space" "onprem" {
  name                  = "OnPremise"
  description           = "On-prem cluster TF execution (op-usxpress-dev and successors)"
  is_default            = false
  is_task_queue_stopped = false
  space_managers_teams  = [var.cloud_platform_team_id]
}
```

### 7.2 Register the on-prem worker pool

```hcl
# terraform/worker-pool.tf
provider "octopusdeploy" {
  alias    = "onprem"
  address  = var.octopus_address
  api_key  = var.octopus_admin_api_key
  space_id = octopusdeploy_space.onprem.id
}

resource "octopusdeploy_worker_pool" "onprem" {
  provider    = octopusdeploy.onprem
  name        = "onprem-workers"
  description = "Workers inside corp VPN — reach op-usxpress-dev API VIP 10.10.82.50:6443"
  sort_order  = 10
}

# Listening tentacles registered out-of-band on the worker hosts;
# they self-register into this pool via thumbprint.
# Worker host inventory + thumbprints tracked in INFRA-1543.
```

Worker hosts: minimum **2** for HA (any TfApply must be able to run if one worker is down). Sizing: 2 vCPU / 4 GiB / 40 GiB disk per worker is sufficient for TF + talosctl + kubectl + helm + aws-cli. Dedicated VMs — **do not co-locate Octopus tentacle on Talos CP or worker nodes.**

### 7.3 Set space-level variables

Space-level (visible to every project in the OnPremise space):

| Variable | Example | Source |
|---|---|---|
| `cluster_name` | `op-usxpress-dev` | static |
| `region` | `us-east-2` | static (matches tfstate bucket region) |
| `aws_account_id` | `700736442855` | USX-Dev |
| `oidc_issuer` | `https://oidc.eks...` (or talos issuer) | from `iaac-talos` outputs |
| `tfstate_bucket` | `lazy-tf-state-65v583i6my68y6x9` | static — see memory `onprem_cluster_tf_state_location` |
| `talos_api_vip` | `10.10.82.50` | static |
| `cloud_eks_source_account` | `064859874041` | for cross-cluster ESO source |

Project-level variables (each project sets its own):

- `TfApply` — boolean, defaults `false`. The ceremony variable.
- `tf_workspace` — usually `default`, sometimes per-cluster.
- `extra_tf_vars` — JSON blob if the project needs over-rides.

See memory pointer `onprem_iaac_talos_dev_env_vars` for the full list iaac-talos expects.

### 7.4 Wire the iaac-talos project binding

```hcl
# terraform/projects/iaac-talos.tf
resource "octopusdeploy_project" "iaac_talos" {
  provider                = octopusdeploy.onprem
  name                    = "iaac-talos"
  description             = "Talos cluster TF for op-usxpress-dev"
  lifecycle_id            = data.octopusdeploy_lifecycles.default.lifecycles[0].id
  project_group_id        = octopusdeploy_project_group.onprem_clusters.id
  default_to_skip_if_already_installed = false
  is_disabled             = false
  tenanted_deployment_mode = "Untenanted"

  versioning_strategy {
    template = "#{Octopus.Version.LastMajor}.#{Octopus.Version.LastMinor}.#{Octopus.Version.NextPatch}"
  }

  connectivity_policy {
    allow_deployments_to_no_targets = true   # TF runs on worker, not on a target
    exclude_unhealthy_targets       = false
  }
}

resource "octopusdeploy_variable" "iaac_talos_tfapply" {
  provider     = octopusdeploy.onprem
  owner_id     = octopusdeploy_project.iaac_talos.id
  name         = "TfApply"
  type         = "String"
  value        = "false"
  description  = "Flip true to apply, then back to false. Never leave true."
  is_sensitive = false
}
```

### 7.5 First TfApply (no-op validation)

1. Merge a trivial whitespace-only PR to `iaac-talos` `feature/op-usxpress-dev`.
2. Set `TfApply = true` in the OnPremise / iaac-talos project.
3. Run a release. Expect: `Plan: 0 to add, 0 to change, 0 to destroy.`
4. Confirm green.
5. Set `TfApply = false`.

If this is green, the space + pool + binding are correct.

### 7.6 Bind remaining projects

Repeat §7.4 pattern for:

- `iaac-risingwave-2` — drives `rw-2` cluster-side TF (IRSA roles, S3 buckets for RW state)
- `iaac-cross-cluster-eso` — bootstrap-only project that runs the runbook to mint the cloud-eks reader token and seed it into the on-prem cluster's `cloud-eks-source` `SecretStore`

Future on-prem TF repos onboard via the same three-resource pattern: `octopusdeploy_project` + `octopusdeploy_variable "TfApply"` + project group membership.

---

## Repo layout (target)

```
iaac-octopus-onprem/
├── README.md                                  # this file
├── terraform/
│   ├── space.tf                               # OnPremise space (§7.1)
│   ├── worker-pool.tf                         # on-prem worker pool (§7.2)
│   ├── variables.tf                           # space-level vars (§7.3)
│   ├── outputs.tf                             # space_id, worker_pool_id for downstream consumers
│   ├── providers.tf                           # octopusdeploy provider config + aliases
│   ├── project-group.tf                       # "OnPrem Clusters" group
│   └── projects/
│       ├── iaac-talos.tf                      # §7.4
│       ├── iaac-risingwave-2.tf               # §7.6
│       └── cross-cluster-eso-secret-seed.tf   # §7.6 — bootstrap-only project
├── runbooks/
│   └── bootstrap-cross-cluster-eso.md         # how the cloud-eks reader token gets minted + seeded
└── .github/
    └── workflows/
        └── tf-plan.yml                        # plan-on-PR (no apply; apply is Octopus's job)
```

State backend: same `lazy-tf-state-65v583i6my68y6x9` bucket in `us-east-2` that holds `iaac-talos` state. Workspace: `iaac-octopus-onprem`. See memory `onprem_cluster_tf_state_location`.

---

## Cross-references — what depends on this space being operational

| Repo | Relationship | Without this space |
|---|---|---|
| `variant-inc/iaac-talos` | cluster TF — currently apply-from-laptop; target is apply-via-OnPremise-space project | Stays apply-from-laptop. No CI/CD audit trail. |
| `variant-inc/iaac-talos-flux-cluster` | Flux-managed (NOT Octopus) — but its bootstrap secrets seeded via Octopus runbook here | Flux works; secret rotation manual. |
| `variant-inc/iaac-talos-flux-platform` | Flux-managed (NOT Octopus) — same secret-seeding dependency | Same — works, rotation manual. |
| `variant-inc/iaac-risingwave-2` | rw-2 cluster-side TF (IRSA, S3) — target is apply-via-this-space | Stays apply-from-laptop. |
| `variant-inc/iaac-cross-cluster-eso` | bootstrap-only runbook for cloud-eks reader token | Token minted by hand; not idempotent. |

Flux repos are **consumed** by Flux on the cluster (not by Octopus), but the **secrets** Flux references are seeded by an Octopus runbook in this space — see "Cluster secrets seeding" below.

---

## Account bootstrap pattern

When a new AWS account joins the on-prem fold (e.g., a successor to `op-usxpress-dev` in another tenant), the bootstrap order is:

1. Account exists, OIDC provider registered (cloud side, via `iaac-eks` or `iaac-account-bootstrap`).
2. Create space-level variable set in OnPremise space with the account's `aws_account_id`, `region`, `oidc_issuer`.
3. Add the account to the worker pool's allowed assume-role list.
4. Create the account-specific project group (or reuse "OnPrem Clusters" if same tenant).
5. Wire `iaac-talos` (or successor cluster TF) for the new account.
6. First TfApply: no-op validation per §7.5.

See memory pointer `onprem_account_bootstrap_pattern` for the equivalent cloud-side pattern this mirrors.

---

## Cluster secrets seeding

The `cross-cluster-eso-secret-seed` Octopus project runs a runbook (not a TfApply) that:

1. Assumes role into the cloud-eks account (`064859874041` for shared services, or per-env).
2. Mints / rotates a least-privilege IAM user or role with `secretsmanager:GetSecretValue` on the cross-cluster prefix.
3. Pushes the access key + secret into the on-prem cluster's `cloud-eks-source` `Secret` in the `external-secrets` namespace.
4. External Secrets Operator on-prem reads this `Secret` to authenticate its `SecretStore`.

This is the **only** Octopus-driven mutation of in-cluster state from this space. Everything else is Terraform.

See memory pointer `onprem_cluster_secrets_pattern` for the canonical seeding flow.

---

## Common gotchas

1. **TfApply left `true`.** Most common operational footgun. A merge auto-applies on next release. **Always flip back.** Consider a scheduled runbook that nags if `TfApply == true` for >2h.
2. **Variable scope confusion.** Octopus has three levels: **space-level** variable sets, **project variables**, and **library variable sets**. Read-vs-write rules:
   - Space-level: shared static facts (cluster name, account id, region).
   - Project: project-specific knobs (`TfApply`, `tf_workspace`).
   - Library: secrets shared across projects (e.g., the cross-cluster ESO source credential after seeding).
   Putting `TfApply` at space level = ceremony bypass risk. Putting `aws_account_id` at project level = drift risk. Keep them separated.
3. **Worker pool sizing.** One worker is a SPOF. If the lone worker is rebooting during an incident, no on-prem TF can run — including any recovery TF. Run **at least 2**.
4. **Tentacle on a Talos node.** Don't. The tentacle process needs root, can pull arbitrary binaries, and TF runs use `kubectl/talosctl` against the same cluster — circular trust. Dedicated VMs only.
5. **Cloud space drift.** If you ever copy a Cloud-space project YAML into the OnPremise space without scrubbing AWS region / VPC / target tags, the apply will run against on-prem with cloud assumptions. Use the project group + naming convention (`iaac-*` only) as a guardrail.
6. **`octopusdeploy` provider version pinning.** The provider has had breaking changes between minor versions. Pin to `~> 0.21` (or whatever the Cloud space is on) and bump deliberately.
7. **Space ID hard-coded downstream.** Once the OnPremise space exists, downstream repos that reference `space_id` need it as a variable, not hard-coded. Surface `space_id` in `outputs.tf`.

---

## Related repos

- `variant-inc/iaac-talos` — on-prem Talos cluster TF (the primary consumer of this space)
- `variant-inc/iaac-talos-flux-cluster` — Flux cluster-level kustomizations
- `variant-inc/iaac-talos-flux-platform` — Flux platform-level kustomizations (Rook-Ceph, Istio, Velero, cert-manager, ESO, etc.)
- `variant-inc/iaac-risingwave-2` — rw-2 cluster-side TF
- `variant-inc/iaac-cross-cluster-eso` — cross-cluster ESO bootstrap runbook
- `variant-inc/iaac-octopus-config` — **NOT** the home for this — that repo holds Cloud-space config only. See memory pointer `onprem_iaac_octopus_config_repo`.

---

## Tickets

| Ticket | Summary | State | Owner | Blocker |
|---|---|---|---|---|
| **INFRA-1535** | OnPremise Octopus space + bootstrap runbook to seed cloud-eks ESO reader token | In Progress | Doke | **External — Octopus admin token** |
| **INFRA-1543** | On-prem worker pool IaC (2x VM provisioning + tentacle registration) | To Do | Doke | **External — depends on INFRA-1535** |
| **INFRA-1544** | Marathon umbrella — on-prem TfApply ceremony parity with cloud | Tracking | Doke | This repo's relationship to the umbrella is captured here. |

**External blocker shape:** Octopus admin token is held by the Octopus space-admin / IT-Ops. Request channel: open INFRA ticket + Slack `#cloud-platform` ping. Once issued, the token goes into 1Password (Cloud Platform vault) under `octopus-admin-api-key` and into the local TF `terraform.tfvars` (gitignored) or AWS Secrets Manager under `cloud-platform/octopus/admin-api-key`. Token is **only** needed for §7.1 (space create) and §7.2 (initial worker pool); after that, a space-scoped API key for the OnPremise space is sufficient and the admin key can be revoked.

---

## What's done vs blocked (2026-06-23 snapshot)

**Done:**
- Repo created.
- Target pattern documented (this README).
- Bootstrap runbook designed end-to-end.
- TF snippets drafted (§7.1–§7.4).

**Blocked on admin token:**
- §7.1 space creation
- §7.2 worker pool creation
- §7.4 project bindings
- §7.5 first TfApply validation

**Not yet started (downstream of unblock):**
- Worker VM provisioning (separate ticket — likely lands in `iaac-talos-infra` or a new `iaac-onprem-workers` repo)
- Migration of `iaac-talos` from apply-from-laptop to apply-via-Octopus
- Migration of `iaac-risingwave-2` from apply-from-laptop to apply-via-Octopus

When the token arrives, §7.1 → §7.5 is the first PR. Target: same day as token receipt.

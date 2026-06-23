# iaac-talos — On-Prem Talos Kubernetes IaC

Terraform for the Knight-Swift on-prem Talos OS Kubernetes clusters (vSphere base, Cilium CNI, Flux CD bootstrap). The first cluster managed here is `op-usxpress-dev`; the same module set is intended to clone forward to `op-usxpress-qa` and `op-usxpress-prod`. This repo owns the cluster lifecycle: vSphere VMs for control plane + workers, Talos machine config + bootstrap, Cilium install, Flux bootstrap into the platform repos, and the AWS-side IRSA + Secrets Manager scaffolding (S3 buckets, IAM roles, OIDC trust, talosconfig SM wrapper) that the cluster depends on. Apply is driven from Octopus, not from laptops.

---

## Cluster topology

| Cluster name        | Region / DC         | AWS account (default provider) | Working branch              | TF state path                                                        | Status            |
|---------------------|---------------------|--------------------------------|-----------------------------|----------------------------------------------------------------------|-------------------|
| `op-usxpress-dev`   | On-prem (Chatt DC)  | `700736442855` USX-Dev         | `feature/op-usxpress-dev`   | `s3://lazy-tf-state-65v583i6my68y6x9/op-usxpress-dev/terraform.tfstate` (us-east-2) | Live              |
| `op-usxpress-qa`    | On-prem (Chatt DC)  | `527101283767` USX-QA          | `feature/op-usxpress-qa`    | TBD (separate bucket per account)                                    | Not yet bootstrapped |
| `op-usxpress-prod`  | On-prem (Chatt DC)  | `937464026810` USX-Prod        | `feature/op-usxpress-prod`  | TBD (separate bucket per account)                                    | Not yet bootstrapped |

`op-usxpress-dev` cluster facts:

- API VIP: `10.10.82.50:6443`
- Control plane (3 nodes, 8 GB RAM each): `10.10.82.29`, `10.10.82.179`, `10.10.82.181`
- Workers (7 nodes, 4 GB RAM each): `10.10.82.21`, `10.10.82.22`, `10.10.82.26`, `10.10.82.27`, `10.10.82.28`, `10.10.82.178`, `10.10.82.180`
- Talos: `v1.32.0` (Kubernetes `v1.32.0`)
- OIDC issuer (for IRSA): `https://d3a7wcnazdrd6p.cloudfront.net`

Other AWS accounts referenced (for cross-account IAM, ECR pulls, playground experiments):

- `786352483360` playground
- `064859874041` devops / ECR
- `700736442855` USX-Dev (default for `op-usxpress-dev`)
- `527101283767` USX-QA
- `937464026810` USX-Prod

---

## Components

| Component          | Description                                                                           |
|--------------------|---------------------------------------------------------------------------------------|
| vSphere VM         | Provisions control plane and worker nodes using a Talos OVA                           |
| Talos              | Installs and configures Talos OS and bootstraps the Kubernetes cluster                |
| Cilium             | CNI install via Helm; kube-proxy replacement; Hubble; L2 announcement of API VIP      |
| Flux               | Bootstraps Flux against the two GitOps repos (cluster + platform)                     |
| IRSA               | OIDC provider + per-workload IAM roles + S3 buckets for in-cluster workloads          |
| Terraform Modules  | Modular design for flexible infrastructure and deployment                             |

---

## Project structure

```text
.
├── deploy/
│   ├── terraform/
│   │   ├── main.tf                        # Module composition for the active cluster
│   │   ├── variables.tf                   # cluster_name, node IPs, Talos version, AWS accounts
│   │   ├── providers.tf                   # aws, vsphere, talos, kubernetes, helm, flux
│   │   ├── outputs.tf                     # kubeconfig path, role ARNs, bucket names, IPs
│   │   ├── risingwave-2-imports.tf        # RW-2 S3 bucket + IAM role adoption (root-module imports)
│   │   ├── talosconfig-secret-import.tf   # SM secret wrapper + declarative ARN-based import
│   │   └── modules/
│   │       ├── cilium/                    # Cilium CNI (Helm release + Hubble)
│   │       ├── flux/                      # Flux bootstrap into the platform repos
│   │       ├── irsa/                      # OIDC provider + per-workload IAM roles + buckets
│   │       ├── talos/                     # Talos machine config + bootstrap + kubeconfig
│   │       └── vsphere_vm/                # vSphere VM cloning for CP + worker pools
│   └── docs/
│       ├── troubleshooting/               # Catalog entries (one per incident class)
│       │   ├── README.md                  # Index
│       │   └── runbooks/
│       │       └── flux-bootstrap-from-scratch.md
│       └── architecture/                  # Topology + decision records
├── octopus/                               # Operational Python + shell scripts (see below)
├── .github/                               # CI workflows
├── deploy.ps1                             # Legacy local-driver shim (kept for break-glass)
└── README.md                              # this file
```

---

## Modules

### `modules/cilium`

Installs Cilium as the CNI via Helm. Pinned chart version is declared in the module's `versions.tf`. Configures kube-proxy replacement, Hubble (UI + Relay), and L2 announcements (Cilium handles the API VIP `10.10.82.50` as an L2-announced IP across the three control-plane nodes; no kube-vip). Inputs: cluster CIDR, service CIDR, API server host/port, Hubble enable flag.

### `modules/flux`

Runs the Flux bootstrap against the cluster's two GitOps repos:

- `variant-inc/iaac-talos-flux-cluster` — cluster-level resources (namespaces, CRDs, base policy)
- `variant-inc/iaac-talos-flux-platform` — platform workloads (Cilium upgrades, cert-manager, ESO, Rook-Ceph, Istio, Velero, monitoring, RW-2, etc.)

For `op-usxpress-dev` the cluster path is `clusters/bm-dev/` in `iaac-talos-flux-cluster:master` and the platform path is `infrastructure/<name>/` in `iaac-talos-flux-platform:op-dev`. Flux is bootstrapped with the deploy keys + GitHub PAT pulled from AWS Secrets Manager.

### `modules/irsa`

Provisions the OIDC provider (one per cluster, fronted by CloudFront so the issuer is publicly resolvable) plus the IAM roles + S3 buckets used by in-cluster workloads. Every role's trust policy is built with `jsonencode` and uses `AssumeRoleWithWebIdentity` keyed on `aws_iam_openid_connect_provider.irsa.arn`. The `sub` condition is templated against `var.cluster_name` so the same module file works unchanged for QA + prod.

Canonical role trust shape:

```hcl
# Trust policy for an in-cluster ServiceAccount (modules/irsa/main.tf)
assume_role_policy = jsonencode({
  Version = "2012-10-17"
  Statement = [{
    Effect    = "Allow"
    Principal = { Federated = aws_iam_openid_connect_provider.irsa.arn }
    Action    = "sts:AssumeRoleWithWebIdentity"
    Condition = {
      StringEquals = {
        "${replace(aws_iam_openid_connect_provider.irsa.url, "https://", "")}:sub" =
          "system:serviceaccount:${var.namespace}:${var.service_account}"
        "${replace(aws_iam_openid_connect_provider.irsa.url, "https://", "")}:aud" = "sts.amazonaws.com"
      }
    }
  }]
})
```

### `modules/talos`

Generates Talos machine config (controlplane + worker) from a templated base, applies it to each node via the Talos provider, runs `bootstrap` on the first CP, and writes out the kubeconfig + talosconfig. Inputs: API VIP, list of CP node IPs, list of worker IPs, Talos version, cluster name. Outputs: kubeconfig path + talosconfig path (the latter is consumed by the SM wrapper described below).

### `modules/vsphere_vm`

Clones VMs from a Talos OS image template in vSphere. Pool definitions for control plane and workers are passed in as variables (count, vCPU, memory, disk, MAC seed for stable IPs via DHCP reservations). The module is intentionally thin — it does NOT install Talos; it just produces booted Talos nodes at known IPs that `modules/talos` then configures.

---

## Requirements

* Terraform `>= 1.3`

* Providers:

    * `vmware/vsphere >= 2.1.1`

    * `siderolabs/talos >= 0.8.0`

    * `hashicorp/aws` (for IRSA, S3, Secrets Manager)

    * `fluxcd/flux` (for the bootstrap module)

    * `hashicorp/kubernetes`, `hashicorp/helm`

* vSphere Environment Prerequisites

    * A Content Library hosting a valid Talos OVA

    * Configured network, datastore, and compute cluster

* AWS Environment Prerequisites

    * CloudFront distribution fronting the OIDC public bucket (provisioned by CDN team ahead of TF apply)

    * S3 backend bucket in the per-cluster account

---

## Configuration

Define variables in a `terraform.tfvars` file or pass them via CLI/environment variables. Under Octopus, these are populated from project + library variables — laptop tfvars are for break-glass only.

### vSphere Settings

| Variable                    | Description                        |
|-----------------------------|------------------------------------|
| `vsphere_user`              | vSphere username                   |
| `vsphere_password`          | vSphere password                   |
| `vsphere_server`            | vSphere server address             |
| `datacenter`                | Name of the vSphere datacenter     |
| `datastore`                 | Datastore for VM storage           |
| `vm_cluster_name`           | vSphere compute cluster name       |
| `vm_folder`                 | Folder path for VMs (within DC)    |
| `network_name`              | Network to attach VM NICs          |
| `content_library_name`      | Name of the content library        |
| `content_library_item_name` | Name of the Talos OVA image        |

### Cluster Configuration

| Variable                      | Description                                |
|-------------------------------|--------------------------------------------|
| `cluster_name`                | Talos Kubernetes cluster name              |
| `control_plane_vip`           | VIP for control-plane API endpoint         |
| `endpoint`                    | Full Kubernetes API endpoint (e.g., `https://192.168.1.100:6443`) |
| `talos_version`               | Talos OS version to deploy                 |

### Node Settings

| Variable                      | Description                                |
|-------------------------------|--------------------------------------------|
| `control_plane_count`         | Number of control-plane nodes              |
| `worker_count`                | Number of worker nodes                     |
| `control_plane_name_prefix`   | Prefix for control-plane VM names          |
| `worker_name_prefix`          | Prefix for worker VM names                 |
| `cp_cpus`, `cp_memory_mb`     | vCPU and RAM for control-plane VMs         |
| `worker_cpus`, `worker_memory_mb` | vCPU and RAM for worker VMs            |
| `disk_size_gb`                | Root disk size in GB for all VMs           |

---

## Branch model

- **Working branch per cluster:** `feature/op-usxpress-dev`, `feature/op-usxpress-qa`, `feature/op-usxpress-prod`. All in-flight work for that cluster is committed there.
- **Do NOT base PRs on `master`.** `master` is the enterprise integration target; opening a PR against `master` will trigger CI paths intended for promotion, not iteration. PRs MUST be opened with base = `feature/op-<cluster>`.
- **Promotion to `master`** is a separate, batched merge done by Cloud Platform after a working branch has stabilized end-to-end on its target cluster. Doke owns these merges manually; do not automate or open speculative `master` PRs.
- **Per-cluster branches are long-lived.** Do not rebase them onto `master` without coordination — the OIDC issuer URL and the SM secret ARN are bound to the cluster identity and live in TF state, not source.

---

## Deployment via Octopus

`terraform apply` is gated by an Octopus variable named `TfApply`. Default value: `false`. The ceremony for every apply:

1. Confirm the working branch (`feature/op-<cluster>`) has the desired commit and that CI is green.
2. In Octopus, set the project variable `TfApply = false` (it should already be `false` — verify, do not assume).
3. Create a release on the `op-usxpress-dev` (or QA / prod) environment. The deployment runs `terraform init` + `terraform plan` only. Read the plan output.
4. If the plan is acceptable, set `TfApply = true` in the Octopus project variables.
5. Re-run the deployment. This time the step runs `terraform apply` against the same plan.
6. **Immediately flip `TfApply = false`** after the apply succeeds. Never leave it set to `true`.

Rules:

- One person flips `TfApply` at a time. Coordinate in `#cloud-platform`.
- Never run `terraform apply` from a laptop against this state. Plans for local review are fine (`terraform plan` is read-only against state), but applies go through Octopus so the audit trail lives in one place.
- If Octopus is unreachable and an apply is urgent, fall back to the recovery path below (S3 tfstate pull, local apply with explicit `-state` flags, then re-upload). This is a break-glass procedure — file a ticket noting that Octopus was bypassed.

---

## Octopus operational scripts

The `octopus/` directory holds the Python + shell automation that drives the Octopus side of the contract — project setup, channel + library variable management, cross-cluster ESO wiring, and per-app onboarding. These run from an operator workstation against the Octopus API; they are not invoked by Terraform.

| Script                                  | Purpose                                                                                       |
|-----------------------------------------|-----------------------------------------------------------------------------------------------|
| `octopus/apply.py`                      | Driver that applies a desired-state config to an Octopus space (idempotent, dry-run capable). |
| `octopus/onboard-app.py`                | Bootstraps an app into Octopus: project, channels, deploy targets, library var sets.          |
| `octopus/mirror-release.py`             | Copies a release from one Octopus space/env to another (cloud→on-prem mirror).                |
| `octopus/bento-import.py`               | Imports a bento manifest (bundled config + variables) into a project.                         |
| `octopus/create-cross-cluster-eso-runbook.py` | Generates the cross-cluster-eso bootstrap runbook for a new app from a template.        |
| `octopus/patch-channels.py`             | Bulk-patches release channels across projects (lifecycle, version rules).                     |
| `octopus/patch-library-vars.py`         | Bulk-patches library variable sets (e.g. rotating shared secrets references).                 |
| `octopus/patch-package-feeds.py`        | Repoints package feeds (e.g. ECR account swap, mirror swap).                                  |
| `octopus/patch-setup-variables.py`      | Patches per-project setup variables that drive the bootstrap steps.                           |
| `octopus/ensure-cluster-secrets.sh`     | Idempotent seeder for the cluster-secrets pattern (k8s + SM).                                 |
| `octopus/apply-bootstrap-perms.sh`      | Applies the bootstrap RBAC required for Octopus to deploy into a new namespace.               |
| `octopus/onprem-development.yaml`       | Desired-state file for the OnPremise Development environment (consumed by `apply.py`).        |
| `octopus/cross-cluster-eso/configure-tentacle.yaml` | Tentacle target config for the cross-cluster-eso bridge worker.                   |
| `octopus/revert-*` scripts              | Inverse operations for each `patch-*` script — pin-and-revert workflow for risky changes.     |

Convention: every `patch-*` script ships with a `revert-*` sibling so a wrong bulk change is reversible without database surgery. Do not write a new `patch-*` script without the matching `revert-*`.

---

## Recent additions — jun23 marathon

The 2026-06-23 push (INFRA-1544 umbrella) added three Terraform-side changes plus catalog content. All of it lives in `deploy/terraform/` + `deploy/docs/`.

### IRSA roles + S3 buckets for Velero and etcd-backup (PR #44)

Two new in-cluster workloads gained AWS-side identity:

- **Velero** — IAM role `velero-op-usxpress-dev` + S3 bucket `velero-op-usxpress-dev` (us-east-2, USX-Dev account). Backs PVC contents via Kopia.
- **etcd-backup** — IAM role `etcd-backup-op-usxpress-dev` + S3 bucket `etcd-snapshots-op-usxpress-dev`. Receives `etcdctl snapshot save` output from a CronJob that runs a multi-container Pod (talosctl image is distroless; sidecar pattern is required).

Both roles use `AssumeRoleWithWebIdentity` against the cluster OIDC provider (`aws_iam_openid_connect_provider.irsa.arn`), with trust scoped to the workload's ServiceAccount via `var.cluster_name` substitution. Both bucket names are `<workload>-${var.cluster_name}` so QA + prod will land with distinct, non-colliding names without code changes.

Wiring shape in `deploy/terraform/` (calls the `modules/irsa` source):

```hcl
module "velero_irsa" {
  source          = "./modules/irsa"
  cluster_name    = var.cluster_name
  namespace       = "velero"
  service_account = "velero"
  policy_json     = data.aws_iam_policy_document.velero.json
  bucket_name     = "velero-${var.cluster_name}"
}

module "etcd_backup_irsa" {
  source          = "./modules/irsa"
  cluster_name    = var.cluster_name
  namespace       = "etcd-backup"
  service_account = "etcd-backup"
  policy_json     = data.aws_iam_policy_document.etcd_backup.json
  bucket_name     = "etcd-snapshots-${var.cluster_name}"
}
```

### Talosconfig AWS Secrets Manager wrapper (PR #48 + PR #49)

The talosconfig (the credential file `talosctl` uses to authenticate to the API on every node) is sensitive and must be retrievable by the platform — but it is **operator-seeded**, not Terraform-managed.

What TF owns (wrapper only):

- The SM secret resource (`aws_secretsmanager_secret`) — name, description, KMS key ID, tags, `recovery_window_in_days = 7`
- `lifecycle.ignore_changes = [secret_string]` so TF never overwrites a rotated value

What TF does NOT own:

- The secret value. No `aws_secretsmanager_secret_version` resource exists. The value is seeded out-of-band with `aws secretsmanager put-secret-value`.

The secret was created manually in the console during cluster bring-up, so it was **adopted** into Terraform via a declarative `import` block in the root module (`deploy/terraform/talosconfig-secret-import.tf`), NOT inside the `modules/irsa` source. Per Terraform's rules, `import` blocks only function from the root module.

```hcl
# deploy/terraform/talosconfig-secret-import.tf
# Wrapper only — the value is seeded by the operator and ignored by TF.

resource "aws_secretsmanager_secret" "talosconfig" {
  name                    = "${var.cluster_name}/talosconfig"
  description             = "talosctl client config for ${var.cluster_name}"
  recovery_window_in_days = 7

  tags = {
    cluster = var.cluster_name
    purpose = "talosconfig"
  }

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Adopt the operator-created secret. AWS provider requires the FULL ARN
# (including the random 6-char suffix), NOT the friendly name.
import {
  to = aws_secretsmanager_secret.talosconfig
  id = "arn:aws:secretsmanager:us-east-2:700736442855:secret:op-usxpress-dev/talosconfig-jZx93J"
}
```

Critical gotchas:

- The AWS provider's `import` for `aws_secretsmanager_secret` requires the **full ARN** (with the trailing random 6-char suffix, e.g. `-jZx93J`). Importing by friendly name will fail with `couldn't find resource`. Retrieve the ARN with:

  ```bash
  # Get the canonical ARN (including suffix) for the import block
  aws secretsmanager describe-secret --secret-id op-usxpress-dev/talosconfig --query ARN --output text
  ```

- **For a new cluster (QA, prod)** with no pre-existing SM secret, **remove the `import` block before the first apply.** Otherwise TF will fail trying to import a non-existent resource. The plain `resource "aws_secretsmanager_secret" "talosconfig"` is enough for greenfield — TF creates it empty, then the operator runs `put-secret-value` to seed it.

Seed the value out-of-band (one-time, after TF creates the wrapper):

```bash
# Operator-only. Read the talosconfig from modules/talos output, then push.
aws secretsmanager put-secret-value \
  --secret-id op-usxpress-dev/talosconfig \
  --secret-string file://talosconfig
```

### Troubleshooting catalog + first runbook (PR #45)

Six catalog entries shipped to `deploy/docs/troubleshooting/` covering recurring incident classes, plus one full runbook:

- `deploy/docs/troubleshooting/runbooks/flux-bootstrap-from-scratch.md` — step-by-step rebuild of the Flux bootstrap when the cluster has lost its Flux state but the cluster itself is healthy.

The catalog is now the canonical home for on-prem troubleshooting (previously scattered across wip notes). Future entries go here.

---

## Other root-module imports

Beyond the talosconfig adoption, the root module also adopts the RisingWave-2 (RW-2) AWS-side resources that were originally created by hand during the RW-2 bring-up. The adoption uses the same declarative `import` block pattern.

### `deploy/terraform/risingwave-2-imports.tf`

Adopts:

- **S3 bucket** `risingwave-data-op-usxpress-dev` — RW-2 hummock state store + checkpoint storage (us-east-2, USX-Dev account).
- **IAM role** `op-usxpress-dev-risingwave-2` — IRSA role for the RW-2 ServiceAccount; trust policy keyed on the same cluster OIDC provider as Velero + etcd-backup.

Pattern parallel to `talosconfig-secret-import.tf`:

- The resource definition lives in the root module so the `import` block can resolve.
- `lifecycle.ignore_changes` is set on the bucket's `versioning` + tagging blocks where the RW-2 operator (not TF) is the source of truth.
- For a new cluster, if no pre-existing RW-2 resources exist, **remove the `import` block** before first apply and let TF create the resources fresh. The downstream RW-2 HelmRelease in `iaac-risingwave-2` will pick them up by name (the names are derived from `var.cluster_name`).

Adopt-only-once principle: once the resources are in TF state, the `import` block is a no-op on subsequent applies but is kept in source to document provenance.

---

## Per-cluster bring-up

To stand up `op-usxpress-qa` or `op-usxpress-prod` (or any future cluster) from this repo:

1. **Create the working branch:** `git checkout -b feature/op-usxpress-qa` off the latest stable point on `master`.
2. **Set `var.cluster_name`** in `deploy/terraform/variables.tf` (or per-environment tfvars) to the new cluster name. Every IRSA role + bucket name + SM secret name flows from this.
3. **Point the AWS provider at the right account.** Update `providers.tf` so the `default` aws provider targets the per-cluster account (USX-QA `527101283767`, USX-Prod `937464026810`). Cross-account roles for ECR pulls + cross-cluster ESO stay on their existing aliased providers.
4. **Set the OIDC issuer URL.** The CloudFront distribution that fronts the OIDC bucket must be provisioned ahead of TF apply (separate request to the CDN team) and the issuer URL recorded in the per-environment tfvars. The IRSA module wires this into the OIDC provider resource.
5. **Update the S3 backend.** Point the backend config at the per-account state bucket. Do not share `lazy-tf-state-65v583i6my68y6x9` across accounts.
6. **REMOVE the talosconfig `import` block** in `deploy/terraform/talosconfig-secret-import.tf` — there is no existing SM secret to adopt. Let TF create the wrapper fresh. After the first apply, run `aws secretsmanager put-secret-value` to seed the value, then re-add the `import` block ONLY if you later need to re-adopt (typically you won't).
7. **REMOVE the RW-2 `import` blocks** in `deploy/terraform/risingwave-2-imports.tf` if QA/prod RW-2 has not been hand-provisioned. Same logic as #6 — let TF create the bucket + role fresh.
8. **Provision vSphere prerequisites:** Talos OS template in the right vSphere folder, DHCP reservations for the planned node IPs, VLAN reachable from the worker network.
9. **First apply via Octopus** with the `TfApply` ceremony above. The first apply will:
   - Clone the VMs
   - Generate + apply Talos config + bootstrap the cluster
   - Install Cilium
   - Create the OIDC provider + IRSA roles + S3 buckets (Velero, etcd-backup, RW-2)
   - Create the talosconfig SM wrapper (empty)
   - Bootstrap Flux against the two GitOps repos
10. **Seed the talosconfig SM value** out-of-band.
11. **Re-add the `import` blocks** referencing the now-known ARNs if you want future re-applies to be idempotent in the event of state loss. Optional but recommended.

---

## Talosconfig SM secret pattern

The talosconfig is the only path back into a cluster when the Kubernetes API is unreachable (e.g. CP OOM cascade — see the 2026-06-17 incident). Losing it means losing the cluster. Therefore:

- **The wrapper lives in Terraform** so that the secret's name, description, KMS key, recovery window, and tags are reproducible and audited.
- **The value lives outside Terraform** so that:
  1. It cannot leak into `terraform.tfstate` (which lives in S3 and could be read by anyone with state access).
  2. Rotation is decoupled from infra apply cadence.
  3. A compromised TF runner cannot exfiltrate it via a malicious plan.

### Seeding the value

After TF creates the wrapper resource for the first time:

```bash
# From the operator workstation that has the freshly generated talosconfig.
# This is the ONLY place the value should ever transit cleartext.
aws secretsmanager put-secret-value \
  --secret-id op-usxpress-dev/talosconfig \
  --secret-string file://talosconfig
```

### Retrieving the value (operator only, break-glass)

```bash
# Pull the talosconfig back out for emergency talosctl access.
aws secretsmanager get-secret-value \
  --secret-id op-usxpress-dev/talosconfig \
  --query SecretString --output text > /tmp/talosconfig
chmod 600 /tmp/talosconfig
talosctl --talosconfig /tmp/talosconfig --nodes 10.10.82.29 version
```

### Rotation

`recovery_window_in_days = 7` is set on the wrapper, so a `delete-secret` against the wrong secret is recoverable for a week. To rotate the talosconfig itself (e.g. CA roll):

1. Regenerate talosconfig from the new cluster CA.
2. `aws secretsmanager put-secret-value --secret-id op-usxpress-dev/talosconfig --secret-string file://talosconfig.new` — this creates a new AWSCURRENT version; the old version becomes AWSPREVIOUS automatically.
3. Verify with `talosctl version` against a node before retiring the old config.
4. No TF run is required — the wrapper ignores `secret_string` changes.

---

## Recovery: pull tfstate from S3

This is the `/onprem-safety` Rule 6 path. Use it when Octopus is unreachable and you need to drive TF locally — or when the cluster has wedged badly enough that you need talosctl access via the SM-stored config.

```bash
# 1. Confirm AWS context (must be the USX-Dev account for op-usxpress-dev).
aws sts get-caller-identity

# 2. Pull the latest tfstate locally (read-only — DO NOT push back unless you ran apply).
aws s3 cp \
  s3://lazy-tf-state-65v583i6my68y6x9/op-usxpress-dev/terraform.tfstate \
  /tmp/op-usxpress-dev.tfstate

# 3. Pull the talosconfig out of SM for direct node access.
aws secretsmanager get-secret-value \
  --secret-id op-usxpress-dev/talosconfig \
  --query SecretString --output text > /tmp/talosconfig
chmod 600 /tmp/talosconfig

# 4. Confirm node reachability before doing anything else.
talosctl --talosconfig /tmp/talosconfig --nodes 10.10.82.29,10.10.82.179,10.10.82.181 version

# 5. If you must run terraform locally, do it against the pulled state explicitly.
#    Do not let the backend pull a fresher copy mid-flight.
cd deploy/terraform
terraform init -backend=false
terraform plan -state=/tmp/op-usxpress-dev.tfstate -var-file=op-usxpress-dev.tfvars
```

After any local apply, push the state back to S3 explicitly and note in the ticket that Octopus was bypassed:

```bash
# Only after a successful local apply — and only if you understand what you changed.
aws s3 cp /tmp/op-usxpress-dev.tfstate \
  s3://lazy-tf-state-65v583i6my68y6x9/op-usxpress-dev/terraform.tfstate
```

The 2026-06-17 CP OOM cascade was resolved via exactly this path: pull tfstate, extract talosconfig, run `talosctl reset` + `talosctl apply-config` against the wedged CP nodes after the Rook CSI pod-spread fix landed.

---

## Outputs

| Output              | Description                                             |
| ------------------- | ------------------------------------------------------- |
| `control_plane_ips` | IP addresses of control-plane nodes                     |
| `worker_ips`        | IP addresses of worker nodes                            |
| `kubeconfig`        | Raw Kubeconfig to access the cluster (sensitive)        |
| `oidc_issuer_url`   | Public OIDC issuer URL (CloudFront-fronted) for IRSA    |
| `velero_role_arn`   | IAM role ARN for the Velero ServiceAccount              |
| `etcd_backup_role_arn` | IAM role ARN for the etcd-backup ServiceAccount      |
| `velero_bucket`     | S3 bucket name for Velero backups                       |
| `etcd_snapshot_bucket` | S3 bucket name for etcd snapshot archive             |

---

## Operational runbooks

- `deploy/docs/troubleshooting/` — catalog of recurring failure modes. One entry per class, each with symptoms, RCA, and fix. Six entries shipped in PR #45 (jun23); add to it as new patterns emerge.
- `deploy/docs/troubleshooting/runbooks/flux-bootstrap-from-scratch.md` — full Flux bootstrap rebuild when the cluster has lost its Flux state but the Kubernetes API is healthy. Covers re-seeding deploy keys, re-running `flux bootstrap`, and reconciling the two GitOps repos.
- `deploy/docs/architecture/` — topology + decisions (CNI choice, L2 announcements for the API VIP, OIDC-via-CloudFront for IRSA).

When adding a new troubleshooting entry: copy an existing file as a template, give it a short kebab-case slug, link it from `deploy/docs/troubleshooting/README.md`, and reference it from the relevant runbook if one exists.

---

## Cleanup

`terraform destroy` against an on-prem cluster is a **destructive, multi-system operation** — it deletes vSphere VMs, drops IAM roles + S3 buckets in AWS, and tears down the OIDC provider that all in-cluster workloads depend on. **Do not run it casually.**

Rules:

- Destroy is gated by the same Octopus `TfApply` ceremony as apply. There is no separate `TfDestroy` toggle; the deployment process must explicitly run `terraform destroy` and the operator must confirm.
- **Never destroy `op-usxpress-dev` while RW-2 or any other tenant workload is live on it.** Coordinate with the workload owner (Tim for RW, Idris for Phase 1 RW) first.
- The talosconfig SM secret has `recovery_window_in_days = 7` — a destroy will schedule it for deletion, not delete it immediately. To recover, run `aws secretsmanager restore-secret` within the window.
- For sandbox-only clusters, the local break-glass form is:

  ```bash
  cd deploy/terraform
  terraform destroy -var-file=<env>.tfvars
  ```

  Even this should only be done with explicit team sign-off.

---

## Common gotchas

### TF import blocks must be in the root module

`import` blocks only resolve from the root module. An `import` block inside `modules/irsa` will be silently ignored and TF will try to create the resource fresh, conflicting with the existing one. The talosconfig SM wrapper import lives in `deploy/terraform/talosconfig-secret-import.tf`, and the RW-2 imports live in `deploy/terraform/risingwave-2-imports.tf`, for exactly this reason — do not move them under a module.

### S3 bucket tag values reject characters that IAM tag values accept

S3 bucket tagging is stricter than IAM tagging. Parentheses, slashes, and `+` will all be rejected when applied to an S3 bucket but silently accepted on IAM roles. If you templatize a tag value across both resource types, keep it to `[A-Za-z0-9_ .:=@-]`. Discovered while tagging the Velero + etcd-backup buckets — the `cluster` tag is now plain `op-usxpress-dev`, not `op-usxpress-dev (USX-Dev)`.

### tfswitch PGP verification fails behind the corp proxy

`tfswitch` defaults to verifying HashiCorp's signing key against `keys.openpgp.org`, which is blocked at the corp egress. Workaround: pre-populate the GPG keyring from the cached key under `~/.tfswitch/keys/` or set `TFSWITCH_SKIP_VERIFY=1` for the install step. Once installed, `terraform` itself is fine — this only affects the version switcher.

### WSL Helm + curl trip on the corp CA

WSL2's default trust store does not include the Knight-Swift corporate root CA, so anything fetching from internal CAs (private chart museums, internal git over HTTPS, occasionally `gh` against Enterprise) fails with `x509: certificate signed by unknown authority`. Install the corp CA into `/usr/local/share/ca-certificates/` and run `update-ca-certificates`. For Helm specifically, export `HELM_TLS_CA_CERT=/etc/ssl/certs/ca-certificates.crt` so the in-process HTTP client picks it up.

### `talosctl` image is distroless

The official `ghcr.io/siderolabs/talosctl` image has no `/bin/sh`. CronJobs that need to combine `talosctl` output with `aws s3 cp` (the etcd-backup pattern) must run two containers in the same Pod sharing an `emptyDir`, NOT a single container with a shell pipeline. The etcd-backup manifest in `iaac-talos-flux-platform` is the reference implementation.

### `aws secretsmanager` import wants the full ARN

See the talosconfig section above. `describe-secret --query ARN` is the only reliable way to get the suffix. Same constraint applies to any future SM-secret adoption (RW-2 credentials, future ESO source secrets, etc.).

### Velero Kopia needs `AWS_REGION`

If Velero is configured with IRSA but Kopia fails with `connect: sts..amazonaws.com`, the BSL config alone is insufficient — Kopia reads `AWS_REGION` from the process env, not from the BSL spec. Set it via `configuration.extraEnvVars` on the Velero Helm release. Do NOT also set it under the chart's other `env:` block — that produces a duplicate-env error and the Pod will CrashLoop silently.

### Bluestore label is the source of truth for OSD identity

When recovering Rook-Ceph OSDs after a node rebuild, the bluestore label on the disk (NOT the K8s `Node` name, NOT the device path) is what Rook uses to re-attach. If you replace a disk and the label survives on the new disk, Rook will try to take it over. Wipe the label explicitly before re-provisioning.

---

## Related repos

- **`variant-inc/iaac-talos-flux-cluster`** — cluster-level Flux resources. Branch `master`, cluster path `clusters/bm-dev/` for `op-usxpress-dev`. This repo's `modules/flux` bootstraps the cluster against this repo.
- **`variant-inc/iaac-talos-flux-platform`** — platform workloads (Cilium upgrades, cert-manager, ESO, Rook-Ceph, Istio gateway, Velero HelmRelease, monitoring stack, Reloader, network policies). Branch `op-dev`, infrastructure path `infrastructure/<name>/`. **PRs against this repo MUST base on `op-dev`, not `main`.**
- **`variant-inc/iaac-risingwave-2`** — RW-2 tenant application repo. Flux-synced from branch `main`. The cluster bringup here provisions the namespace + IRSA pre-reqs (`risingwave-2-imports.tf`); RW-2 owns its own HelmReleases.
- **`variant-inc/iaac-risingwave-onprem`** — Tim's RW deployment repo (namespace `risingwave`). Flux-synced from `main`. Shares the on-prem cluster with RW-2 but lifecycle is independent.
- **`variant-inc/iaac-octopus-onprem`** — Octopus deploy targets, projects, and variables for the on-prem clusters. The `TfApply` variable described above is defined here. Owns the Octopus side of the contract; this repo owns the Terraform side.

---

## Tickets

The 2026-06-23 marathon is tracked under **INFRA-1544** (umbrella). Child tasks land scoped to a single PR each:

- **INFRA-1544** — Umbrella: jun23 close-out for `op-usxpress-dev` IaC + ops handoff
- **INFRA-1545** — Wiring + acceptance criteria for the Velero + etcd-backup IRSA pairs (external blocker: Tim)
- **INFRA-1546** — IRSA roles + S3 buckets for Velero + etcd-backup (this repo, PR #44)
- **INFRA-1547** — Talosconfig AWS Secrets Manager wrapper resource (this repo, PR #48)
- **INFRA-1548** — Talosconfig declarative `import` block + ARN-suffix gotcha doc (this repo, PR #49)
- **INFRA-1549** — Six troubleshooting catalog entries (this repo, PR #45)
- **INFRA-1550** — `flux-bootstrap-from-scratch.md` runbook (this repo, PR #45)
- **INFRA-1551** — Velero PVC backup HelmRelease wiring (platform repo)
- **INFRA-1552** — Velero restore verification on a non-RW namespace (platform repo)
- **INFRA-1553** — etcd-backup CronJob multi-container pattern (platform repo)
- **INFRA-1554** — RW-2 operator supplemental ClusterRole (platform repo)
- **INFRA-1555** — Ceph mgr memory bump 512Mi → 2Gi (platform repo)
- **INFRA-1556** — External-DNS v0.20.0 `target:` requirement fix (platform repo)
- **INFRA-1557** — TF state cross-region replication (external blocker: cloud-ops)

External blockers carried forward past jun23: **INFRA-1545** (Tim), **INFRA-1535 / INFRA-1543** (Octopus admin), **INFRA-1557** (cross-region state, cloud-ops).

---

## References

* [Talos Docs](https://www.talos.dev/latest/)
* [Terraform vSphere Provider](https://registry.terraform.io/providers/vmware/vsphere/latest/docs)
* [Terraform Talos Provider](https://registry.terraform.io/providers/siderolabs/talos/latest/docs)
* [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
* [Cilium L2 Announcements](https://docs.cilium.io/en/stable/network/l2-announcements/)
* [Flux Bootstrap](https://fluxcd.io/flux/installation/bootstrap/)

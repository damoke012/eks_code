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

## Repo layout

```
.
├── modules/
│   ├── cilium/                          # Cilium CNI (Helm release + Hubble)
│   ├── flux/                            # Flux bootstrap into the platform repos
│   ├── irsa/                            # OIDC provider + per-workload IAM roles + buckets
│   ├── talos/                           # Talos machine config + bootstrap + kubeconfig
│   └── vsphere_vm/                      # vSphere VM cloning for CP + worker pools
├── deploy/
│   ├── terraform/
│   │   ├── main.tf                      # Module composition for the active cluster
│   │   ├── variables.tf                 # cluster_name, node IPs, Talos version, AWS accounts
│   │   ├── providers.tf                 # aws, vsphere, talos, kubernetes, helm, flux
│   │   ├── backend.tf                   # S3 backend (lazy-tf-state-65v583i6my68y6x9)
│   │   ├── outputs.tf                   # kubeconfig path, role ARNs, bucket names
│   │   ├── irsa.tf                      # Velero + etcd-backup IRSA wiring (PR #44)
│   │   └── talosconfig-secret-import.tf # SM secret wrapper + declarative import block (PR #48/#49)
│   └── docs/
│       ├── troubleshooting/             # Catalog entries (one per incident class)
│       │   ├── README.md                # Index
│       │   └── runbooks/
│       │       └── flux-bootstrap-from-scratch.md
│       └── architecture/                # Topology + decision records
└── README.md                            # this file
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

## Recent additions — jun23 marathon

The 2026-06-23 push (INFRA-1544 umbrella) added three Terraform-side changes plus catalog content. All of it lives in `deploy/terraform/` + `deploy/docs/`.

### PR #44 — IRSA roles + S3 buckets for Velero and etcd-backup

Two new in-cluster workloads gained AWS-side identity:

- **Velero** — IAM role `velero-op-usxpress-dev` + S3 bucket `velero-op-usxpress-dev` (us-east-2, USX-Dev account). Backs PVC contents via Kopia.
- **etcd-backup** — IAM role `etcd-backup-op-usxpress-dev` + S3 bucket `etcd-snapshots-op-usxpress-dev`. Receives `etcdctl snapshot save` output from a CronJob that runs a multi-container Pod (talosctl image is distroless; sidecar pattern is required).

Both roles use `AssumeRoleWithWebIdentity` against the cluster OIDC provider (`aws_iam_openid_connect_provider.irsa.arn`), with trust scoped to the workload's ServiceAccount via `var.cluster_name` substitution. Both bucket names are `<workload>-${var.cluster_name}` so QA + prod will land with distinct, non-colliding names without code changes.

Wiring shape in `deploy/terraform/irsa.tf`:

```hcl
module "velero_irsa" {
  source          = "../../modules/irsa"
  cluster_name    = var.cluster_name
  namespace       = "velero"
  service_account = "velero"
  policy_json     = data.aws_iam_policy_document.velero.json
  bucket_name     = "velero-${var.cluster_name}"
}

module "etcd_backup_irsa" {
  source          = "../../modules/irsa"
  cluster_name    = var.cluster_name
  namespace       = "etcd-backup"
  service_account = "etcd-backup"
  policy_json     = data.aws_iam_policy_document.etcd_backup.json
  bucket_name     = "etcd-snapshots-${var.cluster_name}"
}
```

### PR #48 + PR #49 — Talosconfig AWS Secrets Manager wrapper

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

### PR #45 — Troubleshooting catalog + first runbook

Six catalog entries shipped to `deploy/docs/troubleshooting/` covering recurring incident classes, plus one full runbook:

- `deploy/docs/troubleshooting/runbooks/flux-bootstrap-from-scratch.md` — step-by-step rebuild of the Flux bootstrap when the cluster has lost its Flux state but the cluster itself is healthy.

The catalog is now the canonical home for on-prem troubleshooting (previously scattered across wip notes). Future entries go here.

---

## Per-cluster bring-up

To stand up `op-usxpress-qa` or `op-usxpress-prod` (or any future cluster) from this repo:

1. **Create the working branch:** `git checkout -b feature/op-usxpress-qa` off the latest stable point on `master`.
2. **Set `var.cluster_name`** in `deploy/terraform/variables.tf` (or per-environment tfvars) to the new cluster name. Every IRSA role + bucket name + SM secret name flows from this.
3. **Point the AWS provider at the right account.** Update `providers.tf` so the `default` aws provider targets the per-cluster account (USX-QA `527101283767`, USX-Prod `937464026810`). Cross-account roles for ECR pulls + cross-cluster ESO stay on their existing aliased providers.
4. **Set the OIDC issuer URL.** The CloudFront distribution that fronts the OIDC bucket must be provisioned ahead of TF apply (separate request to the CDN team) and the issuer URL recorded in the per-environment tfvars. The IRSA module wires this into the OIDC provider resource.
5. **Update the S3 backend.** Point `backend.tf` at the per-account state bucket. Do not share `lazy-tf-state-65v583i6my68y6x9` across accounts.
6. **REMOVE the talosconfig `import` block** in `deploy/terraform/talosconfig-secret-import.tf` — there is no existing SM secret to adopt. Let TF create the wrapper fresh. After the first apply, run `aws secretsmanager put-secret-value` to seed the value, then re-add the `import` block ONLY if you later need to re-adopt (typically you won't).
7. **Provision vSphere prerequisites:** Talos OS template in the right vSphere folder, DHCP reservations for the planned node IPs, VLAN reachable from the worker network.
8. **First apply via Octopus** with the `TfApply` ceremony above. The first apply will:
   - Clone the VMs
   - Generate + apply Talos config + bootstrap the cluster
   - Install Cilium
   - Create the OIDC provider + IRSA roles + S3 buckets
   - Create the talosconfig SM wrapper (empty)
   - Bootstrap Flux against the two GitOps repos
9. **Seed the talosconfig SM value** out-of-band.
10. **Re-add the `import` block** to `talosconfig-secret-import.tf` referencing the now-known ARN, if you want future re-applies to be idempotent in the event of state loss. Optional but recommended.

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

## Operational runbooks

- `deploy/docs/troubleshooting/` — catalog of recurring failure modes. One entry per class, each with symptoms, RCA, and fix. Six entries shipped in PR #45 (jun23); add to it as new patterns emerge.
- `deploy/docs/troubleshooting/runbooks/flux-bootstrap-from-scratch.md` — full Flux bootstrap rebuild when the cluster has lost its Flux state but the Kubernetes API is healthy. Covers re-seeding deploy keys, re-running `flux bootstrap`, and reconciling the two GitOps repos.
- `deploy/docs/architecture/` — topology + decisions (CNI choice, L2 announcements for the API VIP, OIDC-via-CloudFront for IRSA).

When adding a new troubleshooting entry: copy an existing file as a template, give it a short kebab-case slug, link it from `deploy/docs/troubleshooting/README.md`, and reference it from the relevant runbook if one exists.

---

## Common gotchas

### TF import blocks must be in the root module

`import` blocks only resolve from the root module. An `import` block inside `modules/irsa` will be silently ignored and TF will try to create the resource fresh, conflicting with the existing one. The talosconfig SM wrapper import lives in `deploy/terraform/talosconfig-secret-import.tf` for exactly this reason — do not move it under a module.

### S3 bucket tag values reject characters that IAM tag values accept

S3 bucket tagging is stricter than IAM tagging. Parentheses, slashes, and `+` will all be rejected when applied to an S3 bucket but silently accepted on IAM roles. If you templatize a tag value across both resource types, keep it to `[A-Za-z0-9_ .:=@-]`. Discovered while tagging the Velero + etcd-backup buckets — the `cluster` tag is now plain `op-usxpress-dev`, not `op-usxpress-dev (USX-Dev)`.

### tfswitch PGP verification fails behind the corp proxy

`tfswitch` defaults to verifying HashiCorp's signing key against `keys.openpgp.org`, which is blocked at the corp egress. Workaround: pre-populate the GPG keyring from the cached key under `~/.tfswitch/keys/` or set `TFSWITCH_SKIP_VERIFY=1` for the install step. Once installed, `terraform` itself is fine — this only affects the version switcher.

### WSL Helm + curl trip on the corp CA

WSL2's default trust store does not include the Knight-Swift corporate root CA, so anything fetching from internal CAs (private chart museums, internal git over HTTPS, occasionally `gh` against Enterprise) fails with `x509: certificate signed by unknown authority`. Install the corp CA into `/usr/local/share/ca-certificates/` and run `update-ca-certificates`. For Helm specifically, export `HELM_TLS_CA_CERT=/etc/ssl/certs/ca-certificates.crt` so the in-process HTTP client picks it up.

### `talosctl` image is distroless

The official `ghcr.io/siderolabs/talosctl` image has no `/bin/sh`. CronJobs that need to combine `talosctl` output with `aws s3 cp` (the etcd-backup pattern) must run two containers in the same Pod sharing an `emptyDir`, NOT a single container with a shell pipeline. The etcd-backup manifest in `iaac-talos-flux-platform` is the reference implementation.

### `aws secretsmanager` import wants the full ARN

See the talosconfig section above. `describe-secret --query ARN` is the only reliable way to get the suffix.

### Velero Kopia needs `AWS_REGION`

If Velero is configured with IRSA but Kopia fails with `connect: sts..amazonaws.com`, the BSL config alone is insufficient — Kopia reads `AWS_REGION` from the process env, not from the BSL spec. Set it via `configuration.extraEnvVars` on the Velero Helm release. Do NOT also set it under the chart's other `env:` block — that produces a duplicate-env error and the Pod will CrashLoop silently.

### Bluestore label is the source of truth for OSD identity

When recovering Rook-Ceph OSDs after a node rebuild, the bluestore label on the disk (NOT the K8s `Node` name, NOT the device path) is what Rook uses to re-attach. If you replace a disk and the label survives on the new disk, Rook will try to take it over. Wipe the label explicitly before re-provisioning.

---

## Related repos

- **`variant-inc/iaac-talos-flux-cluster`** — cluster-level Flux resources. Branch `master`, cluster path `clusters/bm-dev/` for `op-usxpress-dev`. This repo's `modules/flux` bootstraps the cluster against this repo.
- **`variant-inc/iaac-talos-flux-platform`** — platform workloads (Cilium upgrades, cert-manager, ESO, Rook-Ceph, Istio gateway, Velero HelmRelease, monitoring stack, Reloader, network policies). Branch `op-dev`, infrastructure path `infrastructure/<name>/`. **PRs against this repo MUST base on `op-dev`, not `main`.**
- **`variant-inc/iaac-risingwave-2`** — RW-2 tenant application repo. Flux-synced from branch `main`. The cluster bringup here provisions the namespace + IRSA pre-reqs; RW-2 owns its own HelmReleases.
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

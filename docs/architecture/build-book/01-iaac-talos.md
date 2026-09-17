# Repo 1 — `variant-inc/iaac-talos`

**Repo:** <https://github.com/variant-inc/iaac-talos>
**Read at:** `master` @ [`8c732fc`](https://github.com/variant-inc/iaac-talos/tree/8c732fc),
tag [`v0.2.0`](https://github.com/variant-inc/iaac-talos/releases/tag/v0.2.0), on 2026-09-17.
**Access:** corporate GitHub, on the WSL box — not from a codespace ([[usx-github-enterprise-not-personal]]).

```bash
gh repo clone variant-inc/iaac-talos
```

**What it does:** turns empty vSphere capacity into a running, Flux-managed Kubernetes
cluster with an AWS identity. It is the only repo that creates machines.

Supersedes the relevant part of
[`../op-usxpress-dev-repo-architecture.md`](../op-usxpress-dev-repo-architecture.md)
(2026-03-25), which describes a branch model and a workflow set this repo no longer has.

### Where to look

| What you want | Path |
|---|---|
| The trigger | [`.github/workflows/octo.yaml`](https://github.com/variant-inc/iaac-talos/blob/master/.github/workflows/octo.yaml) |
| Octopus entry point | [`deploy/deploy.ps1`](https://github.com/variant-inc/iaac-talos/blob/master/deploy/deploy.ps1) |
| Wiring, JWKS, SSM, MageRunner SA | [`deploy/terraform/main.tf`](https://github.com/variant-inc/iaac-talos/blob/master/deploy/terraform/main.tf) |
| Every input and its default | [`deploy/terraform/variables.tf`](https://github.com/variant-inc/iaac-talos/blob/master/deploy/terraform/variables.tf) |
| Machine sizes — dev | [`deploy/terraform/envs/dev.tfvars`](https://github.com/variant-inc/iaac-talos/blob/master/deploy/terraform/envs/dev.tfvars) |
| Machine sizes — QA | [`deploy/terraform/envs/qa.tfvars`](https://github.com/variant-inc/iaac-talos/blob/master/deploy/terraform/envs/qa.tfvars) |
| Machine-config patches | [`deploy/terraform/modules/talos/main.tf`](https://github.com/variant-inc/iaac-talos/blob/master/deploy/terraform/modules/talos/main.tf) |
| VM cloning | [`deploy/terraform/modules/vsphere_vm/`](https://github.com/variant-inc/iaac-talos/tree/master/deploy/terraform/modules/vsphere_vm) |
| IRSA + the GHA IAM roles | [`deploy/terraform/modules/irsa/`](https://github.com/variant-inc/iaac-talos/tree/master/deploy/terraform/modules/irsa) |
| Troubleshooting library | [`deploy/docs/troubleshooting/`](https://github.com/variant-inc/iaac-talos/tree/master/deploy/docs/troubleshooting) |
| New-cluster checklist | [`QA-CLUSTER-BOOTSTRAP-CHECKLIST.md`](https://github.com/variant-inc/iaac-talos/blob/master/deploy/docs/troubleshooting/QA-CLUSTER-BOOTSTRAP-CHECKLIST.md) |

> Links point at `master`, so they follow the repo. For the exact state this section was
> written against, swap `master` for `8c732fc` in any of them.

---

## 1. Trigger chain — push to running cluster

```
git push (any branch)
   └── .github/workflows/octo.yaml
         ├── job: validate    — checkout, Go, Terraform, TFLint
         └── job: build       — variant-inc/actions-setup@v2
                                variant-inc/actions-octopus@archive/master/v1
                                  project_name: iaac-talos
                                  space_name:   DevOps
                                  version:      ${{ env.IMAGE_VERSION }}
                                  deploy_scripts_path: deploy
   └── Octopus project "iaac-talos", space DevOps
         └── deploy/deploy.ps1   (runs on an Octopus worker)
               └── terraform init/plan/apply against deploy/terraform
```

```yaml
# .github/workflows/octo.yaml — the whole trigger
on:
  push:
    branches:
      - '**'          # EVERY branch builds and pushes a package to Octopus
```

**Worth knowing:** the workflow only *packages*. It does not apply. Applying is an Octopus
deployment, gated by the `TfApply` variable — see [[octopus-green-but-no-apply]]: a deploy that
prints the plan and skips the apply still reports **Success**. `qa` has had `TfApply=true`
since July, so QA applies live.

### ⚠️ The tfvars files are never read

`deploy.ps1` does **not** pass `-var-file`. Read at `8c732fc`, line 111:

```powershell
ce terraform plan -out=tfplan -input=false -no-color
```

Nothing in that script references `envs/`. Every value arrives as an environment variable,
swept from Octopus parameters at the top of the script:

```powershell
$OctopusParameters.GetEnumerator() `
| Where-Object { $_.Key -like "TF_*" } `
| ForEach-Object { [Environment]::SetEnvironmentVariable($_.Key, $_.Value) }
```

**So `envs/dev.tfvars` and `envs/qa.tfvars` are inert.** They are dated, commented, committed,
and have no effect on any deployment. That is why `control_plane_vip = "TBD-qa-vip"` never
broke anything, and why `manage_platform_secret_values` has never been switchable.

The one-line fix that makes them real:

```powershell
ce terraform plan -out=tfplan -input=false -no-color -var-file="envs/$($env:TF_VAR_env_name).tfvars"
```

Until that lands, adding `envs/prod.tfvars` would create a fourth fiction rather than close a
gap. `ce` is an Octopus-worker wrapper, not a general command — these lines only run there.

---

## 2. What is in the repo

```
.github/workflows/    8 workflows — octo.yaml is the cluster one; the other 7 are
                      account bootstrap, cluster secrets, cross-cluster ESO (x2),
                      app onboarding, release mirroring, onprem setup
deploy/deploy.ps1     the Octopus entry point
deploy/terraform/     root module + 5 sub-modules
deploy/docs/          a substantial troubleshooting library — see §7
octopus/              ~20 python/shell scripts that patch Octopus itself — see §8
```

```
deploy/terraform/
├── main.tf                     wiring, JWKS upload, SSM params, MageRunner SA
├── variables.tf                every input; the defaults matter, see §5
├── envs/dev.tfvars             op-usxpress-dev
├── envs/qa.tfvars              op-usxpress-qa
│                               ── NO prod.tfvars. See §6.
├── providers.tf
├── outputs.tf
├── secrets-values.tf
├── grafana-secret-import.tf        \  bare `import` blocks —
├── talosconfig-secret-import.tf    /  see §6, they break a new env's first plan
├── risingwave-2-imports.tf.dev-only    disabled by FILE EXTENSION, see §6
└── modules/
    ├── vsphere_vm/   clones the Talos OVA from a content library
    ├── talos/        machine configs, bootstrap, kubeconfig
    ├── cilium/       CNI as an inline manifest
    ├── flux/         ⚠️ NO LONGER BOOTSTRAPS FLUX — see §4
    └── irsa/         S3 + CloudFront + IAM OIDC provider + 8 roles
```

The `irsa` module is the largest and least obvious: `cert-manager.tf`, `etcd-backup-role.tf`,
`extd-usxpress-io-role.tf`, `gha-risingwave-pipeline-secrets-role.tf`,
`gha-risingwave-poc-secrets-role.tf`, `github-actions-oidc-provider.tf`, `grafana-secret.tf`,
`risingwave-2-role.tf`, `talosconfig-secret.tf`, `velero-role.tf`. **Cluster creation and
GitHub Actions IAM roles live in the same module** — which is why the RisingWave pipeline's
OIDC trust policy is changed here and not in the pipeline repo ([[two-gha-roles-one-pipeline-repo]]).

---

## 3. How machine sizes are created

**Two mechanisms coexist.** A migration was started and not finished.

`main.tf` picks between them:

```hcl
# Worker pools: if worker_pools map is non-empty, iterate per pool. Otherwise
# fall back to a single implicit "default" pool built from the legacy scalars
# — keeps Dev working unchanged during the migration.
locals {
  effective_worker_pools = length(var.worker_pools) > 0 ? var.worker_pools : {
    default = {
      count        = var.worker_count
      cpus         = var.worker_cpus
      memory_mb    = var.worker_memory_mb
      disk_size_gb = var.disk_size_gb
      ceph_disk_gb = var.worker_ceph_disk_gb
      labels       = {}
      taints       = {}
    }
  }
}
```

### Dev — the legacy scalar path

```hcl
control_plane_count = 3
cp_cpus             = 4
cp_memory_mb        = 8192      # Dev on 8 GB. QA is 16 GB.

worker_pools        = {}        # empty -> fallback path above
worker_count        = 7
worker_cpus         = 4
worker_memory_mb    = 12288
disk_size_gb        = 50
worker_ceph_disk_gb = 50
```

3 control plane + 7 identical workers, no pools, no taints.

### QA — the three-pool path

```hcl
control_plane_count = 3
cp_cpus             = 4
cp_memory_mb        = 16384     # up from Dev's 8 GB, to host security agents (Wiz)

worker_pools = {
  system      = { count = 2, cpus =  4, memory_mb =  8192, disk_size_gb = 100, ceph_disk_gb =   0,
                  labels = { pool = "system" },      taints = {} }
  platform    = { count = 3, cpus =  8, memory_mb = 16384, disk_size_gb = 200, ceph_disk_gb =   0,
                  labels = { pool = "platform" },    taints = { pool = "platform:NoSchedule" } }
  application = { count = 5, cpus = 16, memory_mb = 32768, disk_size_gb = 300, ceph_disk_gb = 500,
                  labels = { pool = "application" }, taints = { pool = "application:NoSchedule" } }
}

# Legacy scalars unused when worker_pools is populated, but must be set
# (Terraform still requires values for declared variables).
worker_count = 0
```

3 control plane + 10 workers in three tainted pools. `ceph_disk_gb = 500` on the application
pool is the **second** disk attached per VM (`extra_disk_size_gb`), which is what Rook-Ceph
consumes.

### ⚠️ Trap: pool metadata is applied BY INDEX

Labels and taints are aligned to nodes positionally, via `sort(keys())` in the root and
`flatten()` in the module outputs:

```hcl
worker_pool_metadata = flatten([
  for pool_key in sort(keys(local.effective_worker_pools)) : [
    for i in range(local.effective_worker_pools[pool_key].count) : {
      pool_name = pool_key
      labels    = local.effective_worker_pools[pool_key].labels
      taints    = local.effective_worker_pools[pool_key].taints
    }
  ]
])
```

**Renaming a pool changes its alphabetical position and silently re-maps every label and taint
after it.** `application` → `apps` would move it behind nothing, but `system` → `sys` reorders
against `platform`. Nothing validates the alignment; there is no error, only workloads landing
on the wrong hardware. Same family as [[kustomize-index-patches-are-fragile]].

---

## 4. Defaults we overrode, and why

### Cilium replaces both the CNI and kube-proxy

```hcl
# modules/talos/main.tf — applied to BOTH control plane and worker configs
cluster = {
  network = { cni = { name = "none" } }   # Talos ships no CNI; Cilium is inlined
  proxy   = { disabled = true }           # Cilium does kube-proxy replacement
}
```

Cilium arrives as a Talos **inline manifest**, so the CNI exists before the first node is
Ready — no chicken-and-egg with a post-bootstrap Helm install.

### Cilium settings, with the reasoning preserved in-line

```hcl
extra_set = {
  # security
  "enableRemoteNodeIdentity"  = "true"
  "encryption.enabled"        = "true"
  "encryption.type"           = "wireguard"
  "encryption.nodeEncryption" = "true"

  # performance
  "routingMode"           = "native"
  "ipv4NativeRoutingCIDR" = "10.244.0.0/16"
  "bandwidthManager.enabled" = "true"
  "bandwidthManager.bbr"     = "true"

  # Load balancing — L2 announcements replace a hardware LB on bare metal
  "l2announcements.enabled"            = "true"
  "l2announcements.leaseDuration"      = "10s"
  "l2announcements.leaseRenewDeadline" = "3s"
  "l2announcements.leaseRetryPeriod"   = "1s"
  "k8sClientRateLimit.qps"   = "80"     # raised: L2 announcements are lease-chatty
  "k8sClientRateLimit.burst" = "200"
  "externalIPs" = "true"

  # istio compatibility
  "socketLB.hostNamespaceOnly" = "true"
  "cni.exclusive"              = "false"
  "l7Proxy"                    = "false"
}
```

**`bpf.masquerade` is deliberately OFF**, and the comment says why:

> Cilium's BPF masquerading … has issues with Istio's use of link-local IPs for Kubernetes
> health checking. Enabling BPF masquerading via `bpf.masquerade=true` is not currently
> supported, and results in non-functional pod health checks in Istio ambient.
> <https://github.com/istio/istio/issues/52208>

Hubble and Prometheus exporters are commented out, not deleted — a deliberate "not yet".

### Synthetic failure domains

Bare metal has no cloud availability zones, so they are invented:

```hcl
nodeLabels = merge(
  { "topology.kubernetes.io/zone" = "${var.cluster_name}-${["a","b","c"][count.index % 3]}" },
  ...
)
```

Workers are round-robined across three synthetic zones so `topologySpreadConstraints` behave.
**These zones are not real failure domains** — three "zones" can share one physical host. Any
availability reasoning that leans on them is reasoning about a label.

### One apiServer patch, assembled from flags

```hcl
# ONE apiServer patch, assembled from the feature flags (locals at top of file).
# Do NOT split this per-feature: two patches both setting extraArgs would depend on
# Talos merging them, and if it replaces instead, IRSA silently breaks.
```

The flags that feed it:

```hcl
apiserver_extra_args = merge(
  var.enable_irsa ? {
    "service-account-issuer" = var.oidc_issuer_url
    "api-audiences"          = "sts.amazonaws.com"
  } : {},
  var.enable_aws_iam_authenticator ? {
    # HOST path. The authenticator's own log prints the in-container path; not this one.
    "authentication-token-webhook-config-file" = "/var/lib/aws-iam-authenticator/kubeconfig.yaml"
    "authentication-token-webhook-cache-ttl"   = "2m0s"
  } : {}
)
```

`/var` is used because it is the writable, persistent host path on Talos — `/etc/kubernetes`
is not.

### Control-plane VIP and hostnames

Every control-plane node gets the same VIP on `eth0` with DHCP alongside it, and an explicit
`hostname-override`, because Talos's default hostname does not match the vSphere VM name:

```hcl
machine = {
  network = {
    hostname   = var.control_plane_vm_names[count.index + 1]
    interfaces = [{ interface = "eth0", dhcp = true, vip = { ip = var.control_plane_vip } }]
  }
  kubelet = { extraArgs = { hostname-override = var.control_plane_vm_names[count.index + 1] } }
}
```

Only `control_plane_ips[0]` is bootstrapped; the others join.

### A hand-rolled readiness wait

```bash
for i in $(seq 1 60); do
  if timeout 5 bash -c "</dev/tcp/${var.control_plane_ips[0]}/50000" 2>/dev/null; then
    echo "Talos API responsive on attempt $i, waiting 30s for CRI and services..."
    sleep 30
    exit 0
  fi
  sleep 5
done
exit 1
```

Port 50000 answering is a proxy for "ready to bootstrap", and the **fixed 30-second sleep** is
the actual readiness guarantee. On a slow day this is a race, and the failure surfaces as a
bootstrap error rather than a timeout. Candidate for replacement with a real health query.

### ⚠️ The flux module no longer bootstraps Flux

`modules/flux/main.tf` at `8c732fc` contains only a wait-for-API provisioner and two
tombstones:

```hcl
removed {
  from = flux_bootstrap_git.this
  lifecycle { destroy = false }
}

removed {
  from = terraform_data.restore_infra_refs
  lifecycle { destroy = false }
}
```

`removed` with `destroy = false` drops the resource from state **without destroying it** —
correct for not tearing Flux out of live clusters, but it means **a new cluster gets no Flux
from Terraform at all.** Whatever bootstraps Flux now is outside this repo's apply; the
candidate is [`runbooks/flux-bootstrap-from-scratch.md`](https://github.com/variant-inc/iaac-talos/blob/master/deploy/docs/troubleshooting/runbooks/flux-bootstrap-from-scratch.md).

The repo README still describes the flux module as bootstrapping Flux. It does not.

### The design rule this repo breaks

> **Anything Terraform creates, Terraform references. It is never round-tripped through a
> tfvars file or an Octopus variable.**

`modules/irsa/talosconfig-secret.tf` creates the secret and outputs its ARN. The root module
*also* takes `talosconfig_secret_arn` as an input variable, and the import block in
`talosconfig-secret-import.tf` consumes that input. Terraform creates the thing, then asks an
operator to tell it what was created. Both Grafana ARNs have the same shape.

That is the whole reason a teardown feels dangerous: a rebuild changes those values and a
human has to chase them back into files.

| Kind | Examples | Belongs in |
|---|---|---|
| **Decisions** — stable across rebuilds | cluster name, VIP, node counts and sizes, vSphere placement, Talos/K8s versions | `envs/<env>.tfvars`, in Git |
| **Facts produced by the build** — change every rebuild | talosconfig ARN, Grafana ARNs, OIDC bucket, CloudFront id, kubeconfig, SSM params | module outputs, referenced directly — never written down |
| **Secrets** | `vsphere_password`, `github_token` | Octopus only |

**The self-seeding mechanism already exists and has never been able to run.**
`secrets-values.tf` writes the talosconfig value from the cluster's own machine secrets:

```hcl
data "talos_client_configuration" "talosconfig" {
  count                = local.seed_secret_values ? 1 : 0
  client_configuration = talos_machine_secrets.cluster.client_configuration
  endpoints            = module.vsphere_cp.ip_addresses
}

resource "aws_secretsmanager_secret_version" "talosconfig" {
  secret_id     = module.irsa[0].talosconfig_secret_arn   # the OUTPUT
  secret_string = data.talos_client_configuration.talosconfig[0].talos_config
}
```

Its own header says it exists *"so a full `terraform destroy` + apply re-seeds itself with
ZERO manual steps"*. It is gated on `manage_platform_secret_values`, which defaults to
`false`, is not set in `qa.tfvars`, and could not take effect from there anyway.

---

## 5. Pinned versions and their defaults

| Thing | Value | Where |
|---|---|---|
| Terraform | **1.9.8** | `deploy/terraform/.terraform-version` |
| Talos | **1.11.1** | both tfvars |
| Kubernetes | **1.32.0** | `modules/talos/variables.tf` default |
| Cilium chart | **1.18.2** | both tfvars (also the variable default) |
| Cilium CLI | `quay.io/cilium/cilium-cli:v0.18.7` | both tfvars |
| AWS region | `us-east-2` | variable default |
| VM settle wait | `sleep_seconds = 60` | variable default |

Feature flags, all defaulting **off**:

| Flag | Default | Dev | QA |
|---|---|---|---|
| `enable_irsa` | `false` | `true` | `true` |
| `enable_aws_iam_authenticator` | `false` | *unset* | `true` |
| `manage_platform_secret_values` | `false` | — | — |
| `enable_rw2_imports` | `false` | `true` | `false` |

`enable_aws_iam_authenticator` is set on QA only — AWS SSO cluster login works there and not
on dev.

---

## 5b. What the LIVE variables say — and where git disagrees

Read from the Octopus **DevOps** space, project `iaac-talos` (`Projects-8283`), 2026-09-17.
Since `deploy.ps1` passes no `-var-file`, **this is the real configuration.** `envs/*.tfvars`
is a parallel description that has never been consulted.

Reproduce with `scripts/octopus-dump-talos-vars.py` in the `eks_code` repo.

### Where each environment actually comes from

| Variable | dev | qa | prod |
|---|---|---|---|
| `TF_VAR_cluster_name` | `op-usxpress-dev` | `op-usxpress-qa` | `op-usxpress-prod` |
| `TF_VAR_control_plane_vip` | `10.10.82.50` | `10.10.82.51` | `10.10.82.52` |
| `TF_VAR_cp_cpus` | **2** (`[ALL]` default) | 4 | 4 |
| `TF_VAR_cp_memory_mb` | 8192 | 16384 | 16384 |
| `TF_VAR_worker_count` | 7 | 0 (pools) | 0 (pools) |
| `TF_VAR_tf_state_bucket` | `op-usxpress-dev-tfstate` | `lazy-tf-state-425rbol87rmn6c7m` | `lazy-tf-state-ipp58n854uhpw13x` |
| `TF_STATE_KEY` | `iaac/talos/op-usxpress-dev.tfstate` | `…op-usxpress-qa.tfstate` | `…op-usxpress-prod.tfstate` |
| `TF_VAR_flux_target_path` | **`clusters/bm-dev`** | `clusters/op-usxpress-qa` | `clusters/op-usxpress-prod` |
| `TfApply` | false (`[ALL]`) | **true** | **true** |
| `AWS_ROLE_TO_ASSUME` | `700736442855:role/octopus-usxpress` | `527101283767:…` | `937464026810:…` |

**The state backend is shared per AWS account** for QA and prod — `lazy-tf-state-*`, with the
cluster distinguished by `TF_STATE_KEY`. Dev is the odd one out on a per-cluster bucket. A new
cluster in an existing account therefore needs **no new bucket**, only a new key.

**`AWS_ROLE_TO_ASSUME` settles who Terraform is:** `octopus-usxpress` in each account. Not
`iaac-octopus-worker-*`, which is the MageRunner/DX identity.

### Flux points at the CLUSTER repo, on master

```
TF_VAR_github_repository = iaac-talos-flux-cluster   [ALL]
TF_VAR_github_branch     = master                    [ALL]
TF_VAR_github_owner      = variant-inc               [ALL]
```

Not `iaac-talos-flux-platform`, and not a per-environment branch. A new cluster needs a
`clusters/<name>/` **directory on `master`** — a PR, not a branch.

### vSphere placement — identical everywhere except the folder

| Variable | Value |
|---|---|
| `vsphere_server` | `usxd1vmvcntrapp.usxpress.com` |
| `vsphere_user` | `svc_terraform` |
| `datacenter` | `D1-Datacenter` |
| `datastore` | `USXD1NTXPROD-SC1` |
| `vm_cluster_name` | `D1 NTX PROD` |
| `network_name` | `10.10.82 (vLAN 82) Prod` |
| `content_library_name` | **`dev-cluster`** — for dev, QA **and production** |
| `content_library_item_name` | `talos-v#{TF_VAR_talos_version}` |
| `vm_folder` | `/KubernetesD1/TalosD1/<cluster>` |

⚠️ **All three environments, production included, pull the Talos OVA from a content library
called `dev-cluster`**, on a network labelled `Prod` and a datastore labelled `PROD`. Either a
shared library with a misleading name, or a copied value nobody revisited. It is what prod
rebuilds from.

### Where `envs/*.tfvars` is factually wrong

Every one of these is inert today and becomes real the moment `TF_USE_VARFILE` is switched on.
**Correct them first; that ordering is the whole of A1.**

| File | Says | Live value |
|---|---|---|
| `qa.tfvars` | `control_plane_vip = "TBD-qa-vip"` | `10.10.82.51` |
| `qa.tfvars` | `github_repository = iaac-talos-flux-platform` | `iaac-talos-flux-cluster` |
| `qa.tfvars` | `github_branch = "op-qa"` | `master` |
| `qa.tfvars` | (no `tf_state_bucket`) | `lazy-tf-state-425rbol87rmn6c7m` |
| `dev.tfvars` | `cp_cpus = 4` | **2** |
| `dev.tfvars` | `github_repository = iaac-talos-flux-platform` | `iaac-talos-flux-cluster` |
| `dev.tfvars` | `github_branch = "op-dev"` | `master` |
| `dev.tfvars` | `flux_target_path = clusters/op-usxpress-dev` | **`clusters/bm-dev`** |
| both | vSphere placement commented out | all nine values present in Octopus |

### Two traps in the `[ALL]`-scoped defaults

```
TF_VAR_cluster_name = #{environment_abbreviation}-cluster   [ALL]
TF_VAR_enable_irsa  = false                                 [ALL]
```

A new environment that does not override `cluster_name` builds a cluster called
`<abbrev>-cluster` — which falls **outside** the IAM grant scoped to `<cluster>-*`, produces
the wrong bucket names, and writes the wrong SSM paths. `environment_abbreviation` itself
defaults to `#{Octopus.Environment.Name | Substring 0 4}`. Neither is validated anywhere.

### IAM is scoped by cluster-name prefix

```json
"Sid": "IAMRoleManagementClusterScoped",
"Resource": [ "arn:aws:iam::527101283767:role/op-usxpress-qa-*",
              "arn:aws:iam::527101283767:role/iaac-octopus-worker-op-usxpress-qa" ]
```

Terraform can create IAM roles **only** for names matching its own cluster prefix. A cluster
named `op-usxpress-qa2` in that account cannot create its eight IRSA roles;
`op-usxpress-qa-2` can. And `octopus/apply-bootstrap-perms.sh` uses `put-role-policy`, which
**replaces** the named policy — running it for a second cluster in an occupied account
de-authorises the first. See [[one-account-one-cluster-assumption]].

> **Instrument note.** `aws iam simulate-principal-policy` without `--resource-arns` simulates
> against `*` and returns `implicitDeny` for a correctly scoped grant. It reported twice that
> Terraform could not create roles, while Terraform was creating eight. Read the policy
> document; do not simulate it.

---

## 6. What is NOT automated

Each of these blocks "push a branch, get a cluster".

| # | Gap | What closing it takes |
|---|---|---|
| 1 | **No `prod.tfvars`.** Dev and QA are declared in Git; prod's values exist only as Octopus variables. | Add `envs/prod.tfvars` mirroring QA, leaving only secrets in Octopus. |
| 2 | **vSphere placement is not in Git.** `datacenter`, `datastore`, `vm_cluster_name`, `vm_folder`, `network_name`, `content_library_name`, `content_library_item_name` are commented out in *both* tfvars and supplied by Octopus. They are not secrets. | Move them into the tfvars. Leave `vsphere_password` and `github_token` in Octopus. |
| 3 | **`qa.tfvars` is factually wrong AND inert** — `control_plane_vip = "TBD-qa-vip"` while QA runs on `10.10.82.51`. Correcting the value alone changes nothing. | Make `deploy.ps1` pass `-var-file` **first**, then correct the values. Order matters. |
| 4 | **`talosconfig_secret_arn` is an output treated as an input**, so it must be seeded by hand and pasted back. The self-seeding code already exists in `secrets-values.tf` and is gated off. | Drop the input variable; reference `module.irsa[0].talosconfig_secret_arn`. Set `manage_platform_secret_values = true` once tfvars are read. |
| 5 | **`risingwave-2-imports.tf.dev-only`** is enabled/disabled by renaming the file. | It is already gated by `enable_rw2_imports`; the rename is redundant. Delete the file — RW-2 is being retired (INFRA-1692). |
| 6 | **Bare `import` blocks** in `talosconfig-secret-import.tf` and `grafana-secret-import.tf` fail a new environment's first plan, because the resource does not exist yet. See [[terraform-import-blocks-block-new-envs]]. | Delete once adopted; a no-op for dev/QA state. |
| 7 | **Terraform does not bootstrap Flux any more** — `flux_bootstrap_git` was `removed`. A new cluster comes up with no Flux. The target branch still has to exist by hand too. | Decide deliberately: restore bootstrap to Terraform, or document the runbook as a required step and stop claiming it is automated. |
| 8 | **A new Octopus environment + variable scoping** is console work. | `iaac-octopus-config` may cover this — verify when we reach repo 4. |
| 9 | **IP/VIP allocation and vSphere capacity** are human decisions. | Will stay manual; document the inputs required. |

### The `octopus/` directory is itself evidence

~20 scripts — `patch-channels.py`, `patch-library-vars.py`, `patch-package-feeds.py`,
`patch-setup-variables.py`, `patch-dx-apply.py` and matching `revert-*.py`. A repo that needs
scripted patch-and-revert of its own deployment engine is describing manual intervention.
Worth reading properly when we reach the Octopus repos.

---

## 7. `deploy/docs/troubleshooting/` — a second book inside repo 1

Not duplicated here; it is the primary record of what the defaults cost us. Seven categories
plus three dated incident timelines (`2026-06-17-cp-oom-cascade`,
`2026-06-18-cilium-orphan-cert-cascade`, `2026-06-19-dns-irsa-rw-cascade`), a
`QA-CLUSTER-BOOTSTRAP-CHECKLIST.md` and `runbooks/flux-bootstrap-from-scratch.md`.

Anyone standing up an environment should read the checklist and the flux-bootstrap runbook
**before** starting, not after it breaks.

---

## 8. Side effects worth knowing about

`main.tf` does three things beyond building a cluster:

1. **Uploads the cluster's JWKS to S3 and invalidates CloudFront**, via a root-level
   `local-exec`, deliberately kept at root to avoid a circular dependency between `irsa` and
   `talos`. It requires `kubectl`, `aws` and `python3` on the Octopus worker. It re-runs only
   when `cluster_name` or the bucket name changes.
2. **Writes four SSM parameters** — `/clusters/<name>/{endpoint,certificate_authority,oidc_issuer,token}`
   — so `terraform-variant-apps` can look up an on-prem cluster without the EKS API.
3. **Creates a `magerunner-deploy` ServiceAccount bound to `cluster-admin`**, with a
   long-lived token stored in SSM as a `SecureString`. This is how app delivery reaches the
   cluster. It is a permanent cluster-admin credential outside the cluster; worth a deliberate
   decision rather than inheritance.

---

## Proven

- Dev = 3 CP (4 CPU / 8 GB) + 7 flat workers (4 CPU / 12 GB / 50 GB). QA = 3 CP (4 CPU / 16 GB)
  + 10 workers in three tainted pools. Read from `envs/*.tfvars` @ `8c732fc`, 2026-09-17.
- `worker_pools` wins when non-empty; QA's legacy scalars are dead entries (`worker_count = 0`).
- Cilium replaces both CNI and kube-proxy, arriving as a Talos inline manifest.
- Talos 1.11.1, Kubernetes 1.32.0, Terraform 1.9.8, Cilium 1.18.2.

## Tested and killed

- *"The repo describes the environments."* It does not. Placement comes from Octopus, prod has
  no tfvars at all, and QA's declared VIP is a placeholder.
- *"Branch = environment."* That was true in March. `master` is now the only long-lived branch;
  environments are selected by tfvars and Octopus scoping.

## Traps

- Pool labels/taints are index-aligned — renaming a pool silently re-maps them.
- `topology.kubernetes.io/zone` is synthetic; it is not a failure domain.
- The bootstrap readiness wait is a TCP probe plus a fixed 30-second sleep.
- A green Octopus deploy does not mean `terraform apply` ran ([[octopus-green-but-no-apply]]).

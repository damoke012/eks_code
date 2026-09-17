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

> **NOT YET READ — `deploy/deploy.ps1`.** The exact variable precedence (whether
> `-var-file=envs/<env>.tfvars` is passed, and whether Octopus `TF_VAR_*` overrides it) is
> unverified. Section 6 depends on it and is marked accordingly.

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
    ├── flux/         Flux bootstrap into iaac-talos-flux-platform
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

## 6. What is NOT automated

Each of these blocks "push a branch, get a cluster".

| # | Gap | What closing it takes |
|---|---|---|
| 1 | **No `prod.tfvars`.** Dev and QA are declared in Git; prod's values exist only as Octopus variables. | Add `envs/prod.tfvars` mirroring QA, leaving only secrets in Octopus. |
| 2 | **vSphere placement is not in Git.** `datacenter`, `datastore`, `vm_cluster_name`, `vm_folder`, `network_name`, `content_library_name`, `content_library_item_name` are commented out in *both* tfvars and supplied by Octopus. They are not secrets. | Move them into the tfvars. Leave `vsphere_password` and `github_token` in Octopus. |
| 3 | **`qa.tfvars` is factually wrong.** `control_plane_vip = "TBD-qa-vip"` while QA runs on `10.10.82.51`; `enable_irsa = true` sits under a comment saying "start OFF". | Correct both — **after** confirming from `deploy.ps1` that Octopus overrides the VIP, so the edit cannot change a live apply. |
| 4 | **`talosconfig_secret_arn` must be seeded by hand before the first apply.** QA's own comment documents the manual `aws secretsmanager create-secret` and pasting the ARN back. Dev's Octopus deploy currently fails on this variable. | A bootstrap step, or a `create-if-absent` data source. |
| 5 | **`risingwave-2-imports.tf.dev-only`** is enabled/disabled by renaming the file. | It is already gated by `enable_rw2_imports`; the rename is redundant. Delete the file — RW-2 is being retired (INFRA-1692). |
| 6 | **Bare `import` blocks** in `talosconfig-secret-import.tf` and `grafana-secret-import.tf` fail a new environment's first plan, because the resource does not exist yet. See [[terraform-import-blocks-block-new-envs]]. | Delete once adopted; a no-op for dev/QA state. |
| 7 | **The Flux target branch must exist first.** `github_branch = "op-qa"` in `iaac-talos-flux-platform` has to be created before bootstrap, by hand. | Create-if-absent in the flux module, or a documented pre-step. |
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

# Standing up a new environment — worked example: `op-usxpress-qa2`

How creating an on-prem cluster **should** work once the confusion in
[01-iaac-talos.md](01-iaac-talos.md) is removed. QA2 is a throwaway built to prove this
document is true; anything it does that is not written here is a defect in the document.

**The test:** hand this page to someone who has never built a cluster. Every step they have to
ask about is a gap we have not closed.

---

## Part A — what must change before QA2 is attempted

None of this is done yet (2026-09-17). These are prerequisites, not options: without them QA2
cannot be built from Git, and the exercise proves nothing.

### A1. Make the tfvars real — `deploy/deploy.ps1`

```powershell
# line 111, today:
ce terraform plan -out=tfplan -input=false -no-color

# what it must become:
ce terraform plan -out=tfplan -input=false -no-color -var-file="envs/$($env:TF_VAR_env_name).tfvars"
```

Add one Octopus variable, `TF_VAR_env_name`, scoped per environment (`dev`, `qa`, `prod`,
`qa2`). Mirror the same flag on the two `terraform plan -destroy` and `terraform apply` calls.

**Everything else in Part A depends on this.** Until it lands, `envs/*.tfvars` is decoration.

### A2. Stop treating outputs as inputs

| Delete from `variables.tf` | Replace every use with |
|---|---|
| `talosconfig_secret_arn` | `module.irsa[0].talosconfig_secret_arn` |
| `grafana_admin_secret_arn` | `module.irsa[0].grafana_admin_secret_arn` |
| `grafana_azure_ad_secret_arn` | `module.irsa[0].grafana_azure_ad_secret_arn` |

Then delete `talosconfig-secret-import.tf` and `grafana-secret-import.tf` entirely. Their only
purpose was adopting hand-made secrets; with Terraform creating them there is nothing to adopt,
and a bare `import` block with an empty id fails a new environment's first plan.

⚠️ **Order of operations for the existing three clusters:** dev, QA and prod already have those
secrets in state via the import blocks. Removing the blocks is a no-op *for them* — the
resources stay in state. Confirm with `terraform state list | grep secretsmanager` on each
before merging. Do not take this on faith.

### A3. Turn on the self-seeding that already exists

In every `envs/*.tfvars`:

```hcl
manage_platform_secret_values = true
```

`secrets-values.tf` then writes the talosconfig from the cluster's own machine secrets, a
random 28-character Grafana admin password, and a placeholder Entra block that real credentials
overwrite and `ignore_changes` preserves. **This is what makes a teardown safe** — every value
regenerates and nobody copies an ARN into a file.

### A4. Move vSphere placement into Git

Seven variables, currently commented out in both tfvars and supplied by Octopus:
`datacenter`, `datastore`, `vm_cluster_name`, `vm_folder`, `network_name`,
`content_library_name`, `content_library_item_name`. None is a secret.

Octopus keeps exactly two: `TF_VAR_vsphere_password` and `TF_VAR_github_token`.

### A5. Make a placeholder impossible

```hcl
variable "control_plane_vip" {
  description = "Virtual IP for the control-plane API endpoint"
  type        = string
  validation {
    condition     = can(cidrnetmask("${var.control_plane_vip}/32"))
    error_message = "control_plane_vip must be an IPv4 address. 'TBD-qa-vip' shipped in qa.tfvars from June to September 2026 and misled every reader, because nothing validated it."
  }
}
```

Same for `endpoint`. This is the difference between "we must remember" and "it cannot happen".

### A6. Decide about Flux — the one open decision

`flux_bootstrap_git` is `removed`. A new cluster therefore gets **no Flux from Terraform**, and
without Flux nothing in Part B past step 6 happens at all.

- **Option 1 — restore it.** One apply produces a fully reconciling cluster. The existing
  `removed` blocks stay so dev/QA/prod are untouched. QA2 proves it works before it is trusted.
- **Option 2 — keep it out, document the runbook as a required manual step**, and stop saying
  cluster creation is automated.

Option 1 is the one consistent with "no manual steps". **This is yours to call.**

### A7. Delete the dead weight

- `risingwave-2-imports.tf.dev-only` — gated by `enable_rw2_imports` already; the file-rename
  toggle is redundant, and RW-2 is being retired (INFRA-1692).
- Fix the `qa.tfvars` VIP and the "start OFF" comment above `enable_irsa = true` — **after** A1,
  so the correction actually means something.

---

## Part B — the standup, step by step

### Step 0 — decisions (human, once)

These are the only things a person invents. Everything else is derived.

| Decision | QA (for reference) | QA2 |
|---|---|---|
| Cluster name | `op-usxpress-qa` | `op-usxpress-qa2` |
| Control-plane VIP | `10.10.82.51` | **needs allocation** |
| Worker/CP IP range | — | **needs allocation** |
| AWS account | `527101283767` | reuse QA's, or a new one |
| vSphere placement | in Octopus today | must be copied to Git (A4) |
| Node shape | 3 CP + 10 workers, 3 pools | **1 CP + 1 worker** — see note |

> **Size it small.** QA2 exists to test the *mechanism*, not the capacity. Full QA shape is 13
> VMs for no extra proof. Keep the three-pool *structure* with `count = 1` each if pool
> behaviour is part of what you are testing; otherwise one flat worker.

⚠️ `cluster_name` propagates into the S3 state bucket, the IRSA OIDC bucket name, the
CloudFront distribution, four SSM parameters, the synthetic zone labels and the Flux target
path. Choosing it is not cosmetic, and teardown must sweep all of them.

### Step 1 — one file in Git

`deploy/terraform/envs/qa2.tfvars` — a copy of `qa.tfvars` with the name, VIP, IPs and node
counts changed. **Nothing else differs**, because everything else is either a decision that is
identical to QA or a fact that regenerates itself.

```hcl
cluster_name = "op-usxpress-qa2"

control_plane_count = 1
cp_cpus             = 4
cp_memory_mb        = 16384

worker_pools = {
  system = { count = 1, cpus = 4, memory_mb = 8192, disk_size_gb = 100, ceph_disk_gb = 0,
             labels = { pool = "system" }, taints = {} }
}
worker_count = 0

control_plane_vip = "10.10.82.XX"          # Step 0, real IP, validated by A5
endpoint          = "https://10.10.82.XX:6443"
talos_version     = "1.11.1"
# ... versions, placement, flags identical to qa.tfvars

manage_platform_secret_values = true       # A3 — self-seeding
enable_irsa                   = true
enable_aws_iam_authenticator  = true
enable_rw2_imports            = false

github_branch    = "op-qa2"                 # must exist — Step 2
flux_target_path = "clusters/op-usxpress-qa2"
tf_state_bucket  = "op-usxpress-qa2-tfstate"
```

No ARNs. No `TBD`. That is the point.

### Step 2 — the two things Terraform cannot create for itself

1. **The Terraform state bucket.** `deploy.ps1` runs
   `terraform init -backend-config="bucket=$S3_BUCKET"` — the bucket must exist before the
   first `init`. A backend cannot bootstrap itself.
   → **`.github/workflows/onprem-account-bootstrap.yaml` probably does this. NOT YET READ.**
2. **The Flux platform branch.** `op-qa2` in `iaac-talos-flux-platform`, branched from `op-qa`.
   Terraform's flux provider points at a branch; it does not create one.

### Step 3 — Octopus scaffolding

A new environment, a worker pool, and these variables scoped to it:

| Variable | Value | Why |
|---|---|---|
| `TF_VAR_env_name` | `qa2` | selects `envs/qa2.tfvars` (A1) |
| `S3_BUCKET` | `op-usxpress-qa2-tfstate` | backend |
| `TF_STATE_KEY` | per convention | backend |
| `AWS_DEFAULT_REGION` | `us-east-2` | backend |
| `TfApply` | `false` at first | plan-only for the first run |
| `TfDestroy` | `false` | |
| `TF_VAR_vsphere_password` | secret | the only two secrets |
| `TF_VAR_github_token` | secret | |

⚠️ **Which space?** `octo.yaml` pushes `iaac-talos` to **DevOps**. The `octopus/` directory
manages **OnPremise** (`Spaces-302`) and is dev-scoped MageRunner routing — a different
concern. The cluster's variables belong in DevOps. *Unverified — Octopus API call still owed.*

### Step 4 — push, and watch the two halves

```
git push origin <branch>
   → .github/workflows/octo.yaml     packages deploy/ and pushes to Octopus (every branch)
   → Octopus release created
```

**Packaging is not applying.** The workflow going green means a package exists.

### Step 5 — plan only

Deploy to the QA2 environment with `TfApply=false`. Read the plan. Expect roughly:

`vsphere_folder` · `vsphere_virtual_machine` ×2 · `talos_machine_secrets` ·
`talos_machine_configuration_apply` ×2 · `talos_machine_bootstrap` ·
`talos_cluster_kubeconfig` · the `irsa` module (S3 bucket, CloudFront, IAM OIDC provider, 8
roles) · 3 secret wrappers + 3 secret versions · 4 SSM parameters · the `magerunner-deploy`
SA, ClusterRoleBinding and token.

**If the plan shows an error about an `import` block, A2 was not finished.**

### Step 6 — apply

Set `TfApply=true` and deploy. What happens, in order:

| # | What | Where |
|---|---|---|
| 1 | Folder + VMs cloned from the Talos OVA, second disk attached if `ceph_disk_gb > 0` | `modules/vsphere_vm` |
| 2 | Machine configs rendered — CNI `none`, kube-proxy disabled, Cilium inlined, apiserver args from the feature flags | `modules/talos` |
| 3 | Wait for port 50000, then a fixed 30s sleep, then bootstrap CP[0] | `modules/talos` |
| 4 | Remaining CPs and workers join; hostnames, VIP, zone labels, pool labels and taints applied | `modules/talos` |
| 5 | IRSA: OIDC S3 bucket, CloudFront, IAM OIDC provider, roles | `modules/irsa` |
| 6 | JWKS fetched from the cluster, uploaded to S3, CloudFront invalidated | `main.tf` root `local-exec` |
| 7 | Secret values seeded — talosconfig from machine secrets, random Grafana password, Entra placeholder | `secrets-values.tf` |
| 8 | 4 SSM parameters written; `magerunner-deploy` SA + cluster-admin binding + token | `main.tf` |
| 9 | Flux — **only if A6 Option 1** | `modules/flux` |
| 10 | Post-apply: SSM validation (hard fail), stuck-namespace recovery, istiod PEM-error restart | `deploy.ps1` |

Steps 6 and 7 are what your "automate the values" ask becomes: **no ARN is ever typed by a
human, and a rebuild regenerates all of them.**

### Step 7 — the platform stack

Flux reconciles `iaac-talos-flux-platform@op-qa2` → Istio, cert-manager, ESO, Argo CD, Kyverno,
Prometheus, Velero, Rook-Ceph. That is repo 3 and its own section of this book.

⚠️ Platform branches are copies and carry the source cluster's role ARNs
([[manifests-copied-across-branches]]). `op-qa2` branched from `op-qa` will reference QA's
ARNs until they are changed. **Diff before trusting it.**

### Step 8 — verify at the thing, not the tick

| Claim | Proof |
|---|---|
| Cluster exists | `kubectl get nodes` — count, labels, taints match `qa2.tfvars` |
| Terraform applied | `terraform_outputs.yml` artifact on the Octopus deploy — not a green tick ([[octopus-green-but-no-apply]]) |
| IRSA works | a pod with a SA annotation gets `AWS_ROLE_ARN` + a token file |
| talosconfig seeded | `aws secretsmanager get-secret-value` returns a real talosconfig, not a placeholder |
| Flux reconciling | `scripts/flux-kustomization-health.sh --cluster op-qa2` — exit 0 |
| Platform healthy | every Kustomization Ready, on the **right** revision |

---

## Part C — teardown

`TfDestroy=true` runs a real pre-destroy drain in `deploy.ps1`: suspends every Flux
Kustomization, deletes HelmReleases and Kustomizations, removes the stale
`v1beta1.external.metrics.k8s.io` apiservice, waits up to 3 minutes for namespaces, force-
finalizes the stragglers, then `flux uninstall`. It is genuinely good and it is why namespaces
do not hang on rebuild.

Terraform does **not** remove:

- the S3 Terraform state bucket (it holds the state doing the removing)
- Secrets Manager entries — `recovery_window_in_days = 7`, so names are blocked for a week
- the `op-qa2` branch in `iaac-talos-flux-platform`
- the Octopus environment, worker pool and variables
- SSM parameters, if the destroy does not reach them

**Write the sweep before the build.** A half-deleted QA2 that blocks its own name for seven
days is a worse outcome than not testing.

---

## What is NOT closed (2026-09-17)

| # | Open | Needed from |
|---|---|---|
| 1 | Octopus variable values, and which space holds them | an authenticated Octopus API call |
| 2 | **Flux bootstrap: restore to Terraform, or accept a manual step?** | Doke |
| 3 | QA2 IP/VIP allocation and vSphere capacity | networking + vSphere |
| 4 | `onprem-account-bootstrap.yaml` and `onprem-cluster-secrets.yaml` — do they already create the state bucket and seed secrets? | reading them |
| 5 | Whether QA2 reuses QA's AWS account or gets its own | Doke + cloud team |

Items 1 and 4 are reads. Item 2 is a decision. Items 3 and 5 are allocations. **None of Part A
has been written yet** — this page is the design, not the state of the repo.

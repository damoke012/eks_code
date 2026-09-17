# Standing up a new environment — worked example: `op-usxpress-qa2`

How creating an on-prem cluster **should** work once the confusion in
[01-iaac-talos.md](01-iaac-talos.md) is removed. QA2 is a throwaway built to prove this
document is true; anything it does that is not written here is a defect in the document.

**The test:** hand this page to someone who has never built a cluster. Every step they have to
ask about is a gap we have not closed.

---

## The whole thing on one page

Every step: what you do, which file acts, which lines do the work, what exists afterwards.
Line numbers are `master` @ `8c732fc`.

### Before the pipeline — 6 steps, 5 of them one-time

| # | Do this | File / place | What it does | After |
|---|---|---|---|---|
| 1 | Decide 6 values | *(human)* | name, VIP, IP range, AWS account, vSphere placement, node shape | decisions exist |
| 2 | Write them down | `deploy/terraform/envs/qa2.tfvars` | the **only** file a person edits | decisions in Git |
| 3 | Create the state bucket | **manual — no automation exists** | a Terraform backend cannot create its own bucket | `op-usxpress-qa2-tfstate` |
| 4 | Bootstrap account IAM | GHA `onprem-account-bootstrap.yaml` → `octopus/apply-bootstrap-perms.sh` | attaches the `iaac-talos-bootstrap` policy to `octopus-usxpress`, scoped `<cluster>-*` | Octopus worker may build |
| 5 | Seed the worker secret | GHA `onprem-cluster-secrets.yaml` → `octopus/ensure-cluster-secrets.sh` | creates `<cluster>/octopus-worker` | ExternalSecrets can resolve |
| 6 | Branch the platform repo | `iaac-talos-flux-platform`, `op-qa2` from `op-qa` | Terraform points at a branch; it never creates one | Flux has somewhere to read |

> ⚠️ **Steps 4 and 5 have never been runnable, for ANY environment.** Proved by dispatch on
> 2026-09-17 (runs `35229647746` lowercase, `35229975054` uppercase — both stop at the first
> step). `iaac-talos` holds exactly one repository secret, `OCTOPUS_API_KEY`. There is no
> `ONPREM_BOOTSTRAP_ROLE_ARN_DEV`, `_QA` or `_PROD`, though both workflow headers document
> them as a prerequisite.
>
> The old code hid this: the `case` had no `*)` branch, so an unmatched or missing value set
> an **empty** role ARN and failed three steps later inside `configure-aws-credentials`,
> reading as a permissions problem. Nobody would diagnose that as "the secret was never
> created".
>
> **Fix is not code.** Someone with the `github-actions-onprem-bootstrap` role ARN per account
> runs `gh secret set ONPREM_BOOTSTRAP_ROLE_ARN_DEV --repo variant-inc/iaac-talos`, and the
> same for `_QA`, `_PROD`, `_QA2`.
>
> **Still unsettled:** whether a lowercase `target_env` resolves an uppercase secret name. It
> could not be tested with no secret present. One dry-run dispatch answers it the moment one
> exists; if lowercase fails, the lookup moves to an exact-name match in bash.

### Octopus — 1 step

| # | Do this | Where | What it does |
|---|---|---|---|
| 7 | New environment + variables | Octopus (**DevOps** space — `octo.yaml` line 38) | `TF_VAR_env_name=qa2`, `S3_BUCKET`, `TF_STATE_KEY`, `AWS_DEFAULT_REGION`, `TfApply=false`, plus the only two secrets: `TF_VAR_vsphere_password`, `TF_VAR_github_token` |

### The pipeline — 3 steps

| # | Do this | File | Lines | What happens |
|---|---|---|---|---|
| 8 | `git push` any branch | `.github/workflows/octo.yaml` | 5–8 trigger, 32–39 package | validates, packages `deploy/`, pushes to Octopus, creates a release. **Packaging is not applying.** |
| 9 | Deploy with `TfApply=false` | `deploy/deploy.ps1` | 15–26 sweep `TF_*` into env vars · 39–43 `init` with the S3 backend · 111 `plan` | a plan you read before anything is built |
| 10 | Set `TfApply=true`, deploy | `deploy/deploy.ps1` | 113–114 `apply` | the sequence below |

### What step 10 actually does, in order

| # | File | Lines | Action |
|---|---|---|---|
| 1 | `main.tf` | 9–13 | creates the vSphere folder |
| 2 | `main.tf` | 15–30 | clones control-plane VMs from the Talos OVA |
| 3 | `main.tf` | 35–47 | picks pools vs legacy scalars (`effective_worker_pools`) |
| 4 | `main.tf` | 64–82 | clones worker VMs per pool, plus the Ceph second disk |
| 5 | `modules/talos/main.tf` | 32–66 | renders the CP machine config — **CNI `none`, kube-proxy disabled**, Cilium inlined, one assembled apiServer patch |
| 6 | `modules/talos/main.tf` | 86–114 | applies config to CP[0] — hostname, VIP on `eth0`, `hostname-override` |
| 7 | `modules/talos/main.tf` | 116–141 | waits for port 50000, then a **fixed 30s sleep** |
| 8 | `modules/talos/main.tf` | 143–148 | bootstraps etcd on CP[0] |
| 9 | `modules/talos/main.tf` | 150–181 | joins the remaining control planes |
| 10 | `modules/talos/main.tf` | 183–224 | joins workers — synthetic `zone` a/b/c, pool labels, pool taints |
| 11 | `modules/talos/main.tf` | 226–230 | retrieves the kubeconfig |
| 12 | `main.tf` | 189–199 | IRSA module — OIDC S3 bucket, CloudFront, IAM OIDC provider, 8 roles |
| 13 | `main.tf` | 218–260 | fetches JWKS from the cluster → S3 → invalidates CloudFront |
| 14 | `secrets-values.tf` | 22–34 | **writes the talosconfig from the cluster's own machine secrets** |
| 15 | `secrets-values.tf` | 37–52 | generates a random 28-char Grafana admin password |
| 16 | `secrets-values.tf` | 55–65 | Entra placeholder, preserved by `ignore_changes` |
| 17 | `main.tf` | 266–309 | writes 3 SSM parameters — endpoint, CA, OIDC issuer |
| 18 | `main.tf` | 317–370 | `magerunner-deploy` SA + cluster-admin binding + token → SSM |
| 19 | `modules/flux/main.tf` | 82–91 | waits for the API. **Bootstraps Flux only if A6 Option 1 is taken** |
| 20 | `deploy.ps1` | 130–162 | validates the 3 SSM parameters — **hard fail** if any is empty |
| 21 | `deploy.ps1` | 164–224 | force-finalizes stuck `Terminating` namespaces |
| 22 | `deploy.ps1` | 226–294 | restarts istiod if its log shows `could not decode pem` |
| 23 | `deploy.ps1` | 115–123 | publishes `terraform_outputs.yml` as an Octopus artifact |

**Steps 14–16 are the answer to "values change on rebuild".** Nobody types an ARN; a teardown
regenerates all of it.

### After the pipeline

| # | What | Where |
|---|---|---|
| 11 | Flux reconciles the platform stack | `iaac-talos-flux-platform@op-qa2` |
| 12 | Verify at the thing, not the tick | Part B step 8 |

### The files a person touches, complete

1. `deploy/terraform/envs/qa2.tfvars` — **the only file with decisions in it**
2. Two GHA workflow dropdowns, to admit a 4th environment
3. Octopus: one environment, six variables, two secrets
4. One new branch in the platform repo

Everything else is generated.

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

| Decision | QA (live value) | QA-2 |
|---|---|---|
| Cluster name | `op-usxpress-qa` | **`op-usxpress-qa-2`** — the hyphen is load-bearing, see Step 1.5 |
| Control-plane VIP | `10.10.82.51` | **the only value still needed** |
| Worker IPs | DHCP | DHCP — not a decision |
| AWS account | `527101283767` | reuse QA's |
| State backend | `lazy-tf-state-425rbol87rmn6c7m`, key `iaac/talos/op-usxpress-qa.tfstate` | same bucket, key `…/op-usxpress-qa-2.tfstate` |
| Node shape | 3 CP + 10 workers, 3 pools | 1 CP + 1 worker |

**vSphere placement — read from Octopus 2026-09-17, closing A4:**

| Variable | Value | Scope |
|---|---|---|
| `datacenter` | `D1-Datacenter` | ALL |
| `datastore` | `USXD1NTXPROD-SC1` | dev, qa, prod |
| `vm_cluster_name` | `D1 NTX PROD` | ALL |
| `vm_folder` | `/KubernetesD1/TalosD1/<cluster>` | per env |
| `network_name` | `10.10.82 (vLAN 82) Prod` | dev, qa, prod |
| `content_library_name` | `dev-cluster` | **all three, including production** |
| `content_library_item_name` | `talos-v#{TF_VAR_talos_version}` | per env |
| `vsphere_server` | `usxd1vmvcntrapp.usxpress.com` | ALL |
| `vsphere_user` | `svc_terraform` | ALL |

⚠️ **Production pulls its Talos OVA from a content library named `dev-cluster`.** Either a
deliberately shared library with a misleading name, or a copied value nobody revisited. Worth
confirming before the next prod rebuild.

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

### ⚠️ Step 1.5 — the naming decision that is not cosmetic

Terraform's IAM grant in each account is **scoped by cluster-name prefix**. Read from QA's
live `octopus-usxpress` role, 2026-09-17:

```json
"Sid": "IAMRoleManagementClusterScoped",
"Action": [ "iam:CreateRole", "iam:PutRolePolicy", ... ],
"Resource": [
  "arn:aws:iam::527101283767:role/op-usxpress-qa-*",
  "arn:aws:iam::527101283767:role/iaac-octopus-worker-op-usxpress-qa"
]
```

`op-usxpress-qa2-*` does **not** match `op-usxpress-qa-*`. Name the cluster `op-usxpress-qa2`
and Terraform cannot create any of its eight IRSA roles — the apply fails partway with an
AccessDenied that reads like a credentials problem.

**Decision: name it `op-usxpress-qa-2`.** That falls inside the existing wildcard, so nothing
needs changing and QA cannot be disturbed.

### ☠️ And do NOT run `apply-bootstrap-perms.sh` for a second cluster in an existing account

```bash
aws iam put-role-policy --role-name "$ROLE" --policy-name iaac-talos-bootstrap ...
```

`put-role-policy` **replaces** the named inline policy, and the document the script writes
covers exactly **one** cluster. Running it in QA's account with `CLUSTER_NAME=op-usxpress-qa2`
would overwrite `op-usxpress-qa-*` and **de-authorise QA's own Terraform** — the next QA apply
fails with AccessDenied on the roles it created itself.

The script's header says *"Run once per account"*. That was true while each account held one
cluster. QA2 is the first time it is not.

**Fix (PR 2):** give each cluster its own inline policy —
`--policy-name "iaac-talos-bootstrap-${CLUSTER_NAME}"`. Inline policies are separate objects,
so no cluster can clobber another, and it needs no read-modify-write.

### Step 2 — what Terraform cannot create for itself

**Corrected 2026-09-17 by reading the live Octopus variables.** Both items were wrong.

1. ~~The Terraform state bucket must be created.~~ **Not for a cluster sharing an existing
   account.** QA's backend is `S3_BUCKET = lazy-tf-state-425rbol87rmn6c7m`, shared per AWS
   account, with the cluster distinguished by `TF_STATE_KEY = iaac/talos/op-usxpress-qa.tfstate`.
   QA-2 reuses that bucket with key `iaac/talos/op-usxpress-qa-2.tfstate` — nothing to create.
   (`octopus/ensure-tfstate-bucket.sh` still matters for a brand-new AWS account. Note dev is
   the odd one out, on a per-cluster `op-usxpress-dev-tfstate`.)
2. ~~A branch `op-qa2` in `iaac-talos-flux-platform`.~~ **Wrong repo and wrong branch.** Octopus
   says, for every environment:

   ```
   TF_VAR_github_repository = iaac-talos-flux-cluster   [ALL]
   TF_VAR_github_branch     = master                    [ALL]
   TF_VAR_flux_target_path  = clusters/op-usxpress-qa   [qa]
   ```

   Flux bootstraps against the **cluster** repo on `master`, into a per-cluster directory —
   not the platform repo on a per-environment branch. `envs/qa.tfvars` says
   `github_repository = "iaac-talos-flux-platform"` and `github_branch = "op-qa"`; both are
   **wrong**, and harmless only because that file is never read.

   What QA-2 actually needs: a `clusters/op-usxpress-qa-2/` directory on `master` of
   `iaac-talos-flux-cluster`, holding the Flux `GitRepository` + `Kustomization` objects that
   point at the platform repo. That is repo 2's job, and it is a PR, not a branch.

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
| 1 | Octopus variable values, and which space holds them | an authenticated Octopus API call — **the repo's `OCTOPUS_API_KEY` is 5 months old and Doke's local key is rejected as "account may have been disabled"**. Likely the same expired credential. |
| 1b | **`ONPREM_BOOTSTRAP_ROLE_ARN_<ENV>` does not exist for any environment** — steps 4 and 5 cannot run | the bootstrap role ARN per account, set as a repo secret |
| 2 | **Flux bootstrap: restore to Terraform, or accept a manual step?** | Doke |
| 3 | QA2 IP/VIP allocation and vSphere capacity | networking + vSphere |
| 4 | ~~Do the bootstrap workflows create the state bucket?~~ **Answered 2026-09-17: no.** `onprem-account-bootstrap.yaml` attaches an IAM policy; `onprem-cluster-secrets.yaml` seeds `<cluster>/octopus-worker`. **The state bucket has no automation at all.** Both also hardcode `options: [dev, qa, prod]` and `ONPREM_BOOTSTRAP_ROLE_ARN_<ENV>`, so a 4th environment cannot be selected. | closed — now 3 fixes |
| 5 | Whether QA2 reuses QA's AWS account or gets its own | Doke + cloud team |

Items 1 and 4 are reads. Item 2 is a decision. Items 3 and 5 are allocations. **None of Part A
has been written yet** — this page is the design, not the state of the repo.

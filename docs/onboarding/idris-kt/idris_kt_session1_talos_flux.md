# Session 1 — iaac-talos + iaac-talos-flux-platform

**Duration:** 90 min
**Goal:** Idris can walk through every TF module in iaac-talos, explain the bootstrap sequence, and trace the Flux dependency chain in iaac-talos-flux-platform.
**Format:** Live code walk-through. Open files in editor, scroll, narrate.

---

## Why this is Session 1

This is the foundation — the actual VMs, OS, cluster. Easiest to reason about because it's tangible (vSphere VMs, IPs, kubeconfig). Everything else (Octopus, terraform-variant-apps, mage-runner) sits on top of this and assumes the cluster exists.

---

## Prerequisites (he should have done this before showing up)

- Cloned `iaac-talos`, `iaac-talos-flux-platform`, `iaac-talos-flux-cluster`.
- Has corp VPN. `kubectl get nodes` against op-usxpress-dev works.
- Read iaac-talos README.

---

## Agenda (90 min)

| Time | Topic |
|------|-------|
| 0–5 | Recap + check homework |
| 5–10 | What is Talos? Why not stock Linux? |
| 10–40 | iaac-talos: TF module walk-through |
| 40–45 | The bootstrap sequence — order of operations |
| 45–55 | Backend / state / GHA workflow |
| 55–80 | iaac-talos-flux-platform: Flux dependency chain + key components |
| 80–90 | Hands-on: trace one Kustomization end-to-end + Q&A |

---

## Section 1 — What is Talos? (5 min)

- Linux distribution purpose-built for Kubernetes.
- **No SSH, no shell.** Everything via the Talos API (gRPC).
- Configured by **machineconfig YAML** — declarative.
- Immutable rootfs. Upgrade = swap the image.
- Why we use it: minimal attack surface, deterministic, API-driven (matches our IaC philosophy).

---

## Section 2 — iaac-talos repo layout (5 min)

```
iaac-talos/
├── .github/workflows/
│   └── octo.yaml                    # GHA: validate TF + push release to Octopus DevOps space
├── deploy/
│   ├── deploy.ps1                   # PowerShell: terraform init/plan/apply (called by Octopus)
│   └── terraform/
│       ├── main.tf                  # Module wiring (vsphere_cp, vsphere_worker, talos, cilium, flux, irsa)
│       ├── providers.tf             # vsphere, talos, flux, aws providers
│       ├── variables.tf             # 60+ root vars (vSphere creds, cluster config, node hardware, etc)
│       ├── outputs.tf               # kubeconfig, IPs, IRSA ARNs, Flux path
│       └── modules/
│           ├── vsphere_vm/          # Provisions VMs on vSphere
│           ├── talos/               # Bootstraps Talos cluster on those VMs
│           ├── cilium/              # Generates Cilium CNI install Job (inline manifest)
│           ├── flux/                # Bootstraps Flux GitOps post-cluster
│           └── irsa/                # OIDC provider + IAM roles for IRSA on Talos
├── README.md
└── LOCAL_TESTING_CHANGES.md         # Notes on what changes locally for WSL2 testing
```

**Key fact**: all five modules are TF modules. The repo's job is to compose them via `main.tf` and feed them variables.

**Current branch**: `feature/op-usxpress-dev` (or `feature/irsa` depending on what's checked out — verify live). Master is the production branch.

---

## Section 3 — TF module walk-through (30 min)

Open each module's `main.tf` in the editor, scroll through, narrate.

### 3.1 — vsphere_vm module (5 min)

**Path:** `deploy/terraform/modules/vsphere_vm/main.tf`
**Purpose:** Provisions VMs on vSphere. Used twice — once for control plane, once for workers.

**Key variables:**
- `vm_count` — how many VMs (e.g., 3 for CP, 5 for workers)
- `name_prefix` — VM name prefix ("talos-cp-op-usxpress-dev")
- `cpus`, `memory_mb`, `disk_size_gb` — per-VM hardware
- `datacenter`, `datastore`, `vm_cluster_name`, `network_name`, `vm_folder` — vSphere infrastructure refs
- `content_library_name`, `content_library_item_name` — path to the Talos OVA image in vSphere content library

**Key resources:**
- `vsphere_virtual_machine.vm` (count = `var.vm_count`) — clones from Talos OVA
  - `wait_for_guest_net_timeout = 0` — don't wait for guest agent (Talos has none)
  - `guest_id = "otherGuest64"` — vSphere doesn't recognize Talos
- `terraform_data.delay_after_vm` — sleeps `sleep_seconds` after VM creation (default 60s) so DHCP can assign IPs
- `data.vsphere_virtual_machine.vm_info` (count = vm_count) — re-reads VMs to get DHCP IPs

**Output:** `ip_addresses` — list of strings (IPs).

**Called from main.tf** twice:
```hcl
module "vsphere_cp" {
  source     = "./modules/vsphere_vm"
  vm_count   = var.control_plane_count
  name_prefix = var.control_plane_name_prefix
  ...
}

module "vsphere_worker" {
  source   = "./modules/vsphere_vm"
  vm_count = var.worker_count
  ...
}
```

**Talking point:** "Why do we need `delay_after_vm`?" — Because Talos has no VMware Tools, vSphere can't tell when the guest is ready. We hard-wait 60s, then query DHCP for IPs. This is brittle but works.

---

### 3.2 — talos module (10 min) — the most important one

**Path:** `deploy/terraform/modules/talos/main.tf`

**Purpose:** Generates machine configs, applies them to nodes, bootstraps the cluster, retrieves kubeconfig.

**Key variables:**
- `cluster_name` — e.g., `op-usxpress-dev`
- `control_plane_vip` — virtual IP for the API (e.g., `10.10.82.50` — note: cluster API endpoint)
- `endpoint` — full URL `https://10.10.82.50:6443`
- `talos_version` — e.g., `1.10.6`
- `control_plane_ips`, `worker_ips` — from `vsphere_vm` outputs
- `inline_manifests` — array of `{name, contents}`. We pass the Cilium install Job here so it runs at bootstrap.

**Key resources (in execution order):**

1. **`talos_machine_secrets.cluster`** — generates cluster CA, client cert, encryption tokens.

2. **`data.talos_machine_configuration.cp`** — data source that *generates* the control-plane machine config YAML.
   - `cluster_name = var.cluster_name`
   - `cluster_endpoint = var.endpoint`
   - `machine_secrets = talos_machine_secrets.cluster.machine_secrets`
   - `cluster_config_patches`:
     - CNI = "none" (Cilium installs post-bootstrap)
     - kubeProxy disabled (Cilium replaces it)
     - inline manifests embedded (Cilium install Job)

3. **`data.talos_machine_configuration.worker`** — same but for workers.

4. **`talos_machine_configuration_apply.init`** — applies the CP config to the **first CP node only** (`var.control_plane_ips[0]`).
   - Patch sets hostname, eth0 DHCP, **VIP binding**:
     ```yaml
     machine:
       network:
         hostname: cp-1
         interfaces:
           - interface: eth0
             dhcp: true
             vip:
               ip: 10.10.82.50
     ```

5. **`talos_machine_bootstrap.init`** — bootstraps the cluster (etcd init + API server start). Depends on step 4. **This is the irreversible step** — once etcd is initialized, can't re-run.

6. **`talos_machine_configuration_apply.join_cp`** — applies CP config to remaining CP nodes (count = `max(cp_count - 1, 0)`). Depends on step 5.

7. **`talos_machine_configuration_apply.join_workers`** — applies worker config to all worker nodes. Depends on step 5.

8. **`talos_cluster_kubeconfig.kube`** — talks to the first CP node, gets kubeconfig.

**Output:** `kubeconfig_raw` — sensitive YAML.

**Talking point:** "Why is bootstrap a separate step from config-apply?" — Talos design. Config-apply just writes YAML to the node. Bootstrap actually starts etcd. Separating them lets you apply config to all nodes first, then run bootstrap exactly once.

**Talking point:** "What if bootstrap fails?" — Cluster is unrecoverable. Destroy and rebuild. We've practiced this — see `phase2_usx_dev_migration_progress.md`.

---

### 3.3 — cilium module (5 min)

**Path:** `deploy/terraform/modules/cilium/main.tf`
**Purpose:** Generates a Kubernetes Job manifest that installs Cilium via `cilium install` CLI at bootstrap time.

**Key variables:**
- `chart_version` (default: `1.18.2`)
- `cli_image` (default: `quay.io/cilium/cilium-cli:v0.18.7`)
- `control_plane_vip` — for the Job's KUBERNETES_SERVICE_HOST env
- `extra_set` — map of additional `--set` flags (50+ Cilium config values in main.tf root)

**What it generates:**
- ServiceAccount + ClusterRoleBinding (admin for the install Job)
- Job spec that runs `cilium install --version <ver> --set <flags>` from the cilium-cli image

**Why this approach:** Cilium can't be installed *before* the cluster has a CNI (chicken-and-egg). We embed the install Job as an **inline manifest** in the Talos machineconfig. Talos applies the Job at bootstrap, the Job installs Cilium, CNI is now functional, the rest of the system unblocks.

**Output:** `inline_manifest` — `{name, contents}` consumed by the talos module.

**Cilium config highlights** (from main.tf, the values passed in `extra_set`):
- WireGuard encryption between nodes
- Native routing (no overlay)
- BBR bandwidth manager
- L2 announcements (ARP-based LB, no BGP — important: we don't have BGP on-prem)
- BPF masquerading **disabled** (Istio compatibility issues)
- L7 proxy disabled (Istio handles L7)

---

### 3.4 — flux module (3 min)

**Path:** `deploy/terraform/modules/flux/main.tf`
**Purpose:** Bootstraps Flux CD post-cluster.

**Key resources:**
- `terraform_data.wait_for_cluster` — local-exec polling `/dev/tcp/<host>/<port>` until the cluster API is reachable. Up to 20 retries, 10s apart.
- `flux_bootstrap_git.this` — actual Flux bootstrap. Sources from `iaac-talos-flux-cluster` repo on the appropriate branch.

**Key variables:**
- `target_path` — path within the Flux repo to sync (e.g., `clusters/op-usxpress-dev`)
- `cluster_endpoint` — host:port

**Talking point:** "What is `target_path`?" — Flux watches a repo, and `target_path` tells it which subdirectory of that repo represents this specific cluster. So `clusters/op-usxpress-dev/` is the entry point for what Flux will reconcile.

---

### 3.5 — irsa module (7 min)

**Path:** `deploy/terraform/modules/irsa/main.tf`
**Purpose:** Set up IRSA (IAM Roles for Service Accounts) on a non-EKS cluster.

This is the **most on-prem-specific** module. On EKS, AWS provides the OIDC discovery endpoint. On Talos, we have to build it ourselves.

**What it creates:**

1. **OIDC discovery on S3 + CloudFront**:
   - `aws_s3_bucket.oidc` — private bucket
   - `aws_s3_object.oidc_discovery` — uploads `.well-known/openid-configuration` and `keys.json` (JWKS derived from Talos's K8s service account signing key)
   - `aws_cloudfront_distribution.oidc` — public CloudFront fronting the bucket (we don't expose S3 directly)
   - `aws_iam_openid_connect_provider.irsa` — registers the CloudFront URL as a trusted OIDC provider in AWS IAM, with zero-thumbprint (AWS ignores CloudFront certs).

2. **Three IAM roles**:
   - **`external_secrets`** — for the External Secrets Operator. SA: `system:serviceaccount:external-secrets:external-secrets`. Permissions: `secretsmanager:GetSecretValue`, `Describe*`, `List*`.
   - **`ecr_credentials`** — for the ECR creds sync CronJob. SA: `system:serviceaccount:ecr-credentials:ecr-credentials-sync`. Policy: `AmazonEC2ContainerRegistryReadOnly`.
   - **`octopus_worker`** — for the on-prem Octopus worker. SA: `system:serviceaccount:octopus:octopusworker`. Permissions: `sts:AssumeRole`, S3 ListBucket/GetObject for `dx-packages*`.

**Outputs:** OIDC issuer URL (the CloudFront domain), provider ARN, role ARNs.

**Why this exists:** Without IRSA, on-prem pods can't authenticate to AWS. With it, ESO can pull from AWS Secrets Manager just like an EKS pod would.

**Connection to Session 6:** the OIDC discovery setup is **half** of the IRSA story. The other half is the **pod-identity-webhook** (in iaac-talos-flux-platform) that mutates pods at admission time to inject AWS env vars. We deep-dive that in Session 6.

---

## Section 4 — Bootstrap sequence (5 min)

Whiteboard the dependency DAG:

```
vsphere_cp (3 VMs)        vsphere_worker (5 VMs)
        \                       /
         \                     /
          \      cilium        /
           \    (manifest)    /
            \      |         /
             v     v        v
              talos module
              ├─ secrets
              ├─ apply config to CP-1
              ├─ bootstrap (etcd init)
              ├─ apply config to CP-2, CP-3
              ├─ apply config to W-1..W-5
              └─ get kubeconfig
                       |
                       v
                   flux module          irsa module (parallel — independent)
                  (bootstrap GitOps)
```

**Talking point:** total runtime is ~15-20 min from `terraform apply` to a usable cluster.

---

## Section 5 — Backend, state, GHA (10 min)

### Backend

`providers.tf`:
```hcl
terraform {
  backend "s3" {}  # Empty config — params injected at init time via -backend-config
}
```

`deploy.ps1` (called by Octopus):
```powershell
terraform init -no-color `
  -backend-config="bucket=$S3_BUCKET" `
  -backend-config="key=iaac/talos/op-usxpress-dev.tfstate" `
  -backend-config="region=$AWS_DEFAULT_REGION" `
  -backend-config="encrypt=true"
```

**State location**: `s3://lazy-tf-state-65v583i6my68y6x9/iaac/talos/op-usxpress-dev.tfstate`
(See [memory: onprem_cluster_tf_state_location.md])

**Important:** the state lives in `usx-dev` (700736442855) us-east-2. NOT in the old `dpl2-local-test-tfstate` bucket. That's a common gotcha for old docs.

### Variables

There's no committed `terraform.tfvars`. `.gitignore` excludes `*.tfvars`. In production, **Octopus injects all values as `TF_VAR_*` env vars**. For local testing, you create your own `terraform.tfvars` (see `LOCAL_TESTING_CHANGES.md`).

Show him a real example from LOCAL_TESTING_CHANGES.md or our session prep:
```hcl
cluster_name              = "op-usxpress-dev"
control_plane_vip         = "10.10.82.50"
endpoint                  = "https://10.10.82.50:6443"
talos_version             = "1.10.6"
control_plane_count       = 3
worker_count              = 5
control_plane_name_prefix = "talos-cp-op-usxpress-dev"
worker_name_prefix        = "talos-wk-op-usxpress-dev"
```

### GHA workflow

**File:** `.github/workflows/octo.yaml`
**Trigger:** push to any branch.
**Jobs:**
1. **validate** — `terraform validate` + `tflint`.
2. **build** — uses `variant-inc/actions-octopus` to push a release to the **DevOps Octopus space** (cloud-side), project `iaac-talos`. Then a human triggers Octopus to deploy.

**Result:** Octopus has a release; click "Deploy" in Octopus UI to actually run `deploy.ps1` against vSphere + AWS.

---

## Section 6 — iaac-talos-flux-platform deep dive (25 min)

Switch repo. Open `iaac-talos-flux-platform/` in editor.

### Layout

```
iaac-talos-flux-platform/
└── infrastructure/
    ├── cert-manager/                   # HelmRelease — TLS cert mgmt
    ├── cert-manager-issuers/           # Self-signed Issuer + Istio root CA
    ├── pod-identity-webhook/           # IRSA webhook (mutates pods)
    ├── external-secrets/               # ESO operator (HelmRelease)
    ├── external-secrets-config/        # ClusterSecretStore for AWS SM
    ├── ecr-credentials/                # CronJob refreshing ECR pull secret
    ├── keda/                           # KEDA HelmRelease
    ├── prometheus/                     # kube-prometheus-stack HelmRelease
    ├── istio/                          # Ambient mesh: base, istiod, cni, ztunnel, istio-csr
    ├── istio-namespace/                # istio-system namespace
    ├── gateway-api/                    # External CRDs
    ├── cilium-lb/                      # Cilium LB IPAM policy
    ├── octopus-worker/                 # On-prem Octopus tentacle (currently SUSPENDED)
    ├── app-namespaces/                 # 30+ app namespaces + SAs with IRSA annotations
    ├── app-secrets/                    # ExternalSecrets pulling from AWS SM
    └── app-deployments/                # Per-app Deployment manifests
```

**Important architectural fact:** this repo only contains **Kustomize manifests**. The Flux **Kustomization CRDs** (with `dependsOn`) live in a sibling repo: `iaac-talos-flux-cluster/clusters/<env>/flux-system/infra.yaml`. That's where the dependency chain is *declared*.

### The Flux dependency chain (open `iaac-talos-flux-cluster/clusters/op-usxpress-dev/flux-system/infra.yaml`)

```
cert-manager (independent)
  ├→ istio-namespace (independent)
  │    └→ cert-manager-issuers (depends: cert-manager, istio-namespace)
  │         └→ istio-csr (depends: cert-manager-issuers)
  │              └→ istio-base (depends: istio-csr)
  │                   └→ istiod (depends: istio-base)
  │                        ├→ istio-cni (depends: istiod)
  │                        └→ ztunnel (depends: istiod)
  │
  ├→ pod-identity-webhook (depends: cert-manager)
  │    ├→ external-secrets (depends: pod-identity-webhook)
  │    │    └→ external-secrets-config (depends: external-secrets)
  │    │
  │    ├→ ecr-credentials (depends: pod-identity-webhook, app-namespaces)
  │    │
  │    └→ app-namespaces (depends: external-secrets, pod-identity-webhook)
  │         └→ app-secrets (depends: app-namespaces, external-secrets-config)
  │              └→ app-deployments (depends: app-secrets, ecr-credentials, keda)
  │
  ├→ keda (depends: cert-manager)
  ├→ prometheus (independent)
  └→ cilium-lb (independent)

[SUSPENDED] octopus-worker (depends: external-secrets-config, ecr-credentials, pod-identity-webhook)
```

**Talking point:** "Why does pod-identity-webhook depend on cert-manager?" — webhook needs TLS certs to receive API server admission requests. cert-manager issues those.

**Talking point:** "Why is octopus-worker suspended?" — Phase C prerequisite (worker IAM role + API key in SM). We're still validating the worker setup. See `octopus_worker_onprem_progress.md`.

### Key components — quick deep-dive

#### cert-manager
- HelmRelease v1.19.1 from `https://charts.jetstack.io`.
- `crds.keep: true` so we don't lose CRDs on uninstall.

#### pod-identity-webhook
- Vendored fork (we maintain in `amazon-eks-pod-identity-webhook` repo, see Session 6).
- Reads SA annotation `eks.amazonaws.com/role-arn` and injects:
  - `AWS_ROLE_ARN` env
  - `AWS_WEB_IDENTITY_TOKEN_FILE` env
  - Volume mount of the projected SA token
- Result: pod can call `sts:AssumeRoleWithWebIdentity` and get AWS creds.

#### external-secrets + external-secrets-config

ESO HelmRelease pinned to `0.12.x`. SA has IRSA annotation:
```yaml
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::700736442855:role/op-usxpress-dev-external-secrets
```

ClusterSecretStore (`external-secrets-config/clustersecretstore.yaml`):
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: default
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-2
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
```

**This is the default route on-prem reads cloud SM secrets.** Pod-identity-webhook injects AWS env into ESO. ESO calls SM via STS AssumeRoleWithWebIdentity. ExternalSecret resources reference this ClusterSecretStore.

#### Cross-cluster ESO (POC, lives in iaac-octopus-overrides → Flux destination here)

For secrets that cloud TF writes *to k8s* instead of SM (e.g., the `<app>-m-u` Mongo X.509 cert):
- A second ClusterSecretStore is created using the **kubernetes provider** with a bearer token from a cloud SA.
- Token created by `bootstrap-onprem-token.sh`.
- See [memory: onprem_cross_cluster_eso_pattern.md].
- **Reminder**: this is POC. SPOF on cloud. Migration path is to put the cert in AWS SM instead.

#### ecr-credentials
- CronJob runs every 6h.
- IRSA-annotated SA: role `op-usxpress-dev-ecr-credentials-sync`.
- Fetches ECR auth tokens from us-east-1 *and* us-east-2 (images live in both).
- Creates `ecr-pull-secret` (docker-registry secret) in every app namespace.
- All Deployments reference this secret in `imagePullSecrets`.

#### keda (event-driven autoscaling)
- HelmRelease 2.19.x.
- Used for Kafka-based scaling on handler apps.
- Depends on cert-manager (webhook TLS).

#### istio (ambient mode)
- **Profile: `ambient`** (no sidecar injection). ztunnel handles per-node traffic capture.
- Cluster: `op-usxpress-dev.talos.mesh.usxpress` (mesh ID).
- `outboundTrafficPolicy.mode: REGISTRY_ONLY` — only routes to registered services. Stricter than default.
- mTLS via cert-manager-istio-csr (uses cert-manager as issuer).
- Why ambient: lower overhead (no sidecar), simpler debugging, less IPC.

#### prometheus
- Minimal: only Prometheus + kube-state-metrics. No Grafana, no AlertManager, no node-exporter (yet).
- 7-day retention, ephemeral storage (no PVC).
- Will expand in Session 6.

#### app-namespaces / app-secrets / app-deployments
- 30+ namespaces, all labeled `istio.io/dataplane-mode: ambient`.
- Each app SA has IRSA annotation: `eks.amazonaws.com/role-arn: arn:aws:iam::700736442855:role/op-usxpress-dev-<app>`.
- ExternalSecrets pull from `dx--<app>-<secret>` paths in AWS SM.
- App Deployments reference `ecr-pull-secret` for image pulls, ExternalSecret-generated K8s Secrets for env (azuread, kafka, kafka-registry, ca-bundle).

---

## Section 7 — Hands-on (10 min)

Pick **brands-api**. Have Idris trace:

1. Open `iaac-talos-flux-platform/infrastructure/app-namespaces/namespaces.yaml` — find `brands-api` namespace.
2. Open `app-namespaces/serviceaccounts.yaml` — find brands-api SA. Read the IRSA role ARN.
3. Open `app-secrets/` — find the ExternalSecret for brands-api.
4. Open `app-deployments/brands-api.yaml` — see the Deployment, the SA reference, the envFrom secrets, the ecr-pull-secret reference.
5. Go to AWS console (or CLI): `aws secretsmanager list-secrets --filters Key=name,Values=dx--brands-api`. Confirm the secret exists and was created by cloud-side TF.
6. `kubectl --context op-usxpress-dev -n brands-api get secret` — see the K8s secret materialized by ESO.
7. `kubectl --context op-usxpress-dev -n brands-api get pods` — pods using the secret.

**This exercise drills home the whole chain**: IRSA → ESO → SM → K8s Secret → Pod env.

---

## Common pitfalls

- **"Why is my new ExternalSecret not syncing?"** — check the SecretStore is `default` (not a typo); check the SM key path matches; check ESO logs for IRSA assume failures.
- **"Why does pod-identity-webhook keep restarting?"** — TLS cert expired or cert-manager not ready. Self-signed Issuer rotates every 90d.
- **"Why are pods in CrashLoopBackOff after a Talos upgrade?"** — CNI may not have come back. Check Cilium pods. The bootstrap Job runs only once at cluster init; upgrades don't re-run it.
- **"My deploy is ImagePullBackOff."** — `ecr-pull-secret` may have expired. CronJob runs every 6h. Force run: `kubectl create job --from=cronjob/ecr-credentials-sync ecr-sync-manual -n ecr-credentials`.

---

## Homework before Session 2

1. Read `iaac-octopus-overrides/README.md`.
2. Log into Octopus, navigate to OnPremise space (Spaces-302). Click around — projects, library variable sets, environments.
3. Do the hands-on tracing exercise above for one *other* app (geo-handler, attrition-api, or io-notifications-handler). Send screenshots/notes in Slack.
4. One question for Session 2.

---

## Reference cheat sheet

| Concept | Where it lives |
|---|---|
| Cluster TF | `iaac-talos/deploy/terraform/` |
| Cluster TF state | `s3://lazy-tf-state-65v583i6my68y6x9/iaac/talos/op-usxpress-dev.tfstate` |
| Flux Kustomizations (the deps) | `iaac-talos-flux-cluster/clusters/op-usxpress-dev/flux-system/infra.yaml` |
| Flux platform manifests | `iaac-talos-flux-platform/infrastructure/` |
| Cluster API | `https://10.10.82.50:6443` |
| K8s context | `op-usxpress-dev` |
| Account | 700736442855 (USX-Development), us-east-2 |
| Talos version | 1.10.6 (verify) |
| Kubernetes version | 1.32.0 |

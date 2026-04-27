# Session 5 — iaac-eks (RisingWave's home)

**Duration:** 90 min
**Goal:** Idris can read iaac-eks code, understand cluster module composition + addon pattern, and locate the right place to add RisingWave. By end of session, he has a draft PR plan for RisingWave.
**Format:** Live code walk + design discussion.

---

## Why this is Session 5

By now Idris understands every layer below (cluster, Octopus, TF, mage). Now he meets the **cloud cluster** he'll actually deploy RisingWave to. Sessions 1-4 are platform plumbing; Session 5 is his project's home.

---

## Prerequisites

- Cloned `iaac-eks`.
- Read sessions 0-4 docs.
- AWS access to USX-Dev (700736442855), can `aws eks describe-cluster --name usxpress-dev`.

---

## Agenda (90 min)

| Time | Topic |
|------|-------|
| 0–5 | Recap |
| 5–15 | Repo layout + 3 cluster pattern |
| 15–35 | Cluster module deep dive (TF) |
| 35–50 | Addon pattern: how cert-manager / ESO / Karpenter etc. are deployed |
| 50–60 | IRSA on EKS (compare to on-prem from Session 1) |
| 60–75 | Where RisingWave will land — design discussion |
| 75–85 | Hands-on: read one addon's TF module |
| 85–90 | Q&A + homework |

---

## Section 1 — Repo layout (10 min)

iaac-eks is owned by cloud team. We won't push to it without Vibin sign-off, but Idris will (for RisingWave).

```
iaac-eks/
├── .github/workflows/
│   └── octo.yaml                    # Push release to Octopus DevOps space
├── deploy/
│   ├── deploy.ps1                   # PowerShell wrapper for terraform
│   └── terraform/
│       ├── main.tf                  # Module composition for current env
│       ├── providers.tf
│       ├── variables.tf
│       ├── outputs.tf
│       └── modules/
│           ├── cluster/             # EKS control plane + node groups
│           ├── networking/          # VPC, subnets, security groups (often a pre-req env)
│           ├── addons/              # cert-manager, ESO, Karpenter, etc.
│           ├── irsa/                # OIDC + IAM roles for SAs
│           └── ...                  # Various per-feature modules
├── envs/                            # Per-env tfvars (or branches per env)
│   ├── dev.tfvars
│   ├── qa.tfvars
│   └── prod.tfvars
└── README.md
```

**State buckets:**
- `s3://lazy-tf-state-0k3nc997arlf7k1a/us-east-1/dev/terraform.tfstate` (dev — usxpress-dev cluster)
- `s3://lazy-tf-state-...../us-east-1/qa/...` (qa — qa-one)
- `s3://lazy-tf-state-...../us-east-1/prod/...` (prod — usxpress-prod)

(Note: regions sometimes differ — verify from current state. Some clusters in us-east-2.)

**Three clusters:**

| Cluster | Account | Profile | Region |
|---|---|---|---|
| usxpress-dev | 700736442855 | usx-dev | us-east-2 |
| qa-one | 527101283767 | usx-qa | us-east-2 |
| usxpress-prod | 937464026810 | ops-controller | us-east-2 |

---

## Section 2 — Cluster module deep dive (20 min)

Open `modules/cluster/main.tf`.

### Key resources

1. **`aws_eks_cluster`** — the control plane.
   - `name = var.cluster_name`
   - `version` — Kubernetes version (typically pinned, e.g., 1.31)
   - `vpc_config` — subnets, security groups
   - `endpoint_public_access` / `endpoint_private_access` — both enabled in our setup
   - `enabled_cluster_log_types` — audit, authenticator, etc.

2. **EKS node groups** — managed node groups for system pods (cluster autoscaler, CoreDNS, etc.)
   - Worker nodes for apps come from **Karpenter** (more on that in Section 3).
   - Typically 2-3 t3.medium for system; Karpenter spins up app nodes.

3. **`aws_iam_role` for cluster** — the EKS cluster service role.

4. **`aws_iam_openid_connect_provider`** — the OIDC provider for IRSA. Comes for free from EKS (cluster.identity[0].oidc[0].issuer is the issuer URL).

### Variables (read variables.tf)

- `cluster_name` — e.g., `usxpress-dev`
- `kubernetes_version` — e.g., `1.31`
- `vpc_id`, `subnet_ids` — from networking module
- `node_groups` — list of objects defining managed node groups
- `tags` — standardized tags

### Outputs

Critical outputs that other modules consume:
- `cluster_endpoint`
- `cluster_oidc_issuer_url`
- `cluster_certificate_authority`
- `cluster_arn`

### Provider auth

EKS clusters use **kubeconfig generated from cluster output**. Pattern in `providers.tf`:

```hcl
provider "kubernetes" {
  host                   = module.cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(module.cluster.cluster_certificate_authority)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.cluster.cluster_endpoint
    cluster_ca_certificate = base64decode(module.cluster.cluster_certificate_authority)
    exec { ... }
  }
}
```

---

## Section 3 — Addon pattern (15 min)

Each cluster has a set of addons. iaac-eks deploys them via TF (some via helm_release, some via raw kubectl_manifest, some via aws_eks_addon).

### Categories of addons

1. **AWS-managed addons** (`aws_eks_addon`):
   - vpc-cni, coredns, kube-proxy, ebs-csi-driver
   - Lifecycle managed by AWS; we just declare versions.

2. **Helm-deployed addons** (`helm_release`):
   - cert-manager (TLS)
   - external-secrets (ESO)
   - karpenter (autoscaler — recent migration from cluster-autoscaler)
   - aws-load-balancer-controller
   - metrics-server
   - prometheus / grafana (or just kube-state-metrics; some have full monitoring)
   - istio (if mesh-enabled cluster)
   - keda (event-driven autoscaling)

3. **TF-managed Kubernetes resources** (`kubernetes_manifest`):
   - ClusterSecretStores
   - Karpenter NodePools, EC2NodeClasses
   - IngressClasses
   - StorageClasses

### Common addon module pattern

`modules/addons/cert-manager/main.tf`:

```hcl
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.19.1"
  namespace        = "cert-manager"
  create_namespace = true

  set {
    name  = "crds.enabled"
    value = "true"
  }
  set {
    name  = "crds.keep"
    value = "true"
  }
  # ...
}
```

### Karpenter (worth knowing)

Recent migration from cluster-autoscaler. Karpenter:
- Watches pending pods, provisions EC2 instances on demand.
- Defines NodePools (TF: `kubernetes_manifest "nodepool_default"`) with constraints (instance types, AZs, capacity types).
- Terminates idle nodes after consolidation window.

For RisingWave, we'll likely add a dedicated NodePool (memory-optimized, gp3 storage, dedicated taint) so RisingWave compute pods don't compete with general workloads.

---

## Section 4 — IRSA on EKS vs Talos (10 min)

This is worth contrasting because Idris just learned Talos IRSA in Session 1.

### EKS IRSA (cloud)

- EKS provides the OIDC discovery endpoint **automatically**: `https://oidc.eks.us-east-2.amazonaws.com/id/<cluster-id>`.
- `aws_iam_openid_connect_provider` registers it with IAM.
- App SAs are annotated `eks.amazonaws.com/role-arn: arn:...`.
- The EKS pod identity webhook (built into EKS) injects `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE` into pods.
- Pod calls `sts:AssumeRoleWithWebIdentity` with the projected SA token, gets short-lived AWS creds.

### Talos IRSA (on-prem)

- We **build** the OIDC discovery endpoint:
  - JWKS derived from K8s SA signing key.
  - Hosted on S3 + CloudFront.
- `aws_iam_openid_connect_provider` registers the CloudFront URL.
- We **vendor** the EKS pod identity webhook (`amazon-eks-pod-identity-webhook` repo) — it runs as a Deployment in `pod-identity-webhook` namespace.
- Same SA annotation pattern.
- Same `AssumeRoleWithWebIdentity` flow.

**Net result:** identical from the app's perspective. The only difference is who hosts the OIDC discovery endpoint (AWS vs. our CloudFront).

For RisingWave, since it'll deploy to EKS first, this is all built-in. He doesn't need to think about Talos IRSA for his project — but he should know it exists.

---

## Section 5 — Where RisingWave will land (15 min)

### Vibin's direction (March 31)

> "RisingWave is an iaac-eks pattern, not a new repo. Add it as an addon module."

So RisingWave goes into `iaac-eks/modules/addons/risingwave/`.

### Architectural shape (our recommendation, to align with Idris in Session 7)

**Components:**
1. **RisingWave operator** (CRD-based) — install via Helm.
2. **RisingWave cluster CR** — define meta/compute/compactor/frontend nodes.
3. **S3 state store** — RisingWave's storage backend. New AWS S3 bucket per env.
4. **IAM role** — RisingWave needs S3 access. IRSA SA + role.
5. **Postgres metadata** — RisingWave uses PG for cluster metadata. Either a new RDS instance or an existing one.
6. **Networking** — RisingWave frontend exposes a Postgres-protocol endpoint. ClusterIP at first; later add NLB or VPC endpoint.

**Probable layout:**

```
modules/addons/risingwave/
├── main.tf                  # Module composition
├── variables.tf             # cluster_name, env, s3_bucket_name, db_*, sizes
├── outputs.tf
├── operator.tf              # helm_release for risingwave-operator
├── cluster.tf               # kubernetes_manifest for the RisingWave CR
├── s3.tf                    # aws_s3_bucket for state store
├── iam.tf                   # IAM role + IRSA trust + policy
├── postgres.tf              # RDS metadata DB or use existing
└── networking.tf            # Service definition (add NLB later)
```

Then `main.tf` for usx-dev calls:

```hcl
module "risingwave" {
  source = "./modules/addons/risingwave"
  count  = var.enable_risingwave ? 1 : 0

  cluster_name = var.cluster_name
  env          = var.env
  oidc_issuer  = module.cluster.cluster_oidc_issuer_url
  s3_bucket_name = "risingwave-state-${var.env}-${var.account_id}"
  postgres = {
    host = aws_db_instance.risingwave.endpoint
    user = "risingwave"
    password = data.aws_secretsmanager_secret_version.risingwave_pg.secret_string
  }
  size = "small"  # small | medium | large
}
```

### Open questions for him to resolve in Session 7

- Sizing: how many compute/compactor nodes? Metadata DB sizing?
- Postgres: shared with another service or dedicated?
- Network: kept internal or exposed for app teams to query?
- State store: shared S3 or per-env? Encryption? Lifecycle policy?
- Monitoring: how to integrate with our Prometheus stack?
- Upgrade strategy: in-place or blue-green?

These are the design decisions Idris will own in his project doc.

---

## Section 6 — Hands-on: read one addon (10 min)

Pick an existing addon — recommend `external-secrets` since he's seen ESO on-prem.

Open `modules/addons/external-secrets/main.tf`. Trace:
- `helm_release` setup.
- IRSA role created locally or referenced from another module.
- ClusterSecretStore manifest applied.
- Outputs that downstream modules consume.

Have Idris compare to `iaac-talos-flux-platform/infrastructure/external-secrets/`. Same end state, different mechanism (TF on EKS vs. Flux on Talos).

---

## Common pitfalls

- **State drift**: cloud team has been migrating between TF state buckets. Always check current `backend.tf` for the canonical bucket.
- **Region inconsistency**: some clusters in us-east-1, some us-east-2. Read tfvars carefully.
- **EKS version skew**: don't bump kubernetes_version without coordinating with cloud team.
- **Karpenter NodePool gotchas**: hard taints on a NodePool require matching tolerations on workloads. RisingWave NodePool with a `dedicated=risingwave:NoSchedule` taint requires the pods to tolerate.
- **IRSA trust policy typos**: subject must be `system:serviceaccount:<ns>:<sa>` exactly. Wrong namespace = silent assume failure. Debug via CloudTrail.

---

## Homework before Session 6

1. Read `eks_production_environment_analysis.md` for the cloud cluster overview.
2. Read 2-3 addon modules end-to-end (cert-manager, external-secrets, karpenter).
3. Sketch a draft PR for RisingWave in iaac-eks. Just structure (file names, module skeleton). Don't write TF yet.
4. Send the draft to Dare for review before Session 6.

---

## Reference cheat sheet

| Thing | Value |
|---|---|
| Repo | `variant-inc/iaac-eks` |
| Dev cluster | `usxpress-dev` (700736442855, us-east-2) |
| QA cluster | `qa-one` (527101283767, us-east-2) |
| Prod cluster | `usxpress-prod` (937464026810, us-east-2) |
| Dev TF state | `s3://lazy-tf-state-0k3nc997arlf7k1a/us-east-1/dev/terraform.tfstate` (verify region) |
| OIDC issuer (EKS) | EKS-provided, e.g., `https://oidc.eks.us-east-2.amazonaws.com/id/<cluster-id>` |
| Karpenter NodePool path | `modules/addons/karpenter/` |
| RisingWave target path | `modules/addons/risingwave/` (to be created) |

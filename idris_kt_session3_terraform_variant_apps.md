# Session 3 — terraform-variant-apps

**Duration:** 90 min
**Goal:** Idris can read a real spec.yaml, predict which TF modules will run, and explain the on-prem fork gates (`use_eks_api`, extraSecrets injection, mongo-atlas v2).
**Format:** Live code walk + spec.yaml reading exercise.

---

## Why this is Session 3

Octopus (Session 2) drives mage-runner. Mage-runner drives terraform-variant-apps. So before we cover mage-runner, Idris needs to know what terraform-variant-apps actually *does* — otherwise mage-runner just looks like glue around a black box.

---

## Prerequisites

- Cloned `terraform-variant-apps` (cloud-team repo) on `feature/onprem-support` branch.
- Has read at least one app's `spec.yaml` (suggest brands-api).

---

## Agenda (90 min)

| Time | Topic |
|------|-------|
| 0–5 | Recap |
| 5–15 | Repo layout + module taxonomy |
| 15–35 | Module deep-dive: api, auth, mongodb_user, kafka, postgres, role, namespace, replicator |
| 35–50 | The eks-data module — the architectural bottleneck |
| 50–70 | The fork gates (`use_eks_api`, extraSecrets, mongo v2) |
| 70–80 | Walk through brands-api spec.yaml end-to-end |
| 80–90 | Hands-on + Q&A |

---

## Section 1 — Repo layout (10 min)

```
terraform-variant-apps/
├── modules/
│   ├── common/
│   │   ├── eks-data/               # ⭐ Reads EKS cluster info — the bottleneck
│   │   ├── replicator/             # K8s ConfigMap recording deployment metadata
│   │   ├── namespace/              # Creates K8s namespace
│   │   ├── tags/                   # Standardized AWS tags
│   │   ├── auth/                   # Azure AD app registration
│   │   └── mongodb-user/           # Mongo Atlas user (creates user + cert)
│   ├── infrastructure/
│   │   ├── buckets/                # S3 buckets
│   │   ├── kafka/                  # Confluent Cloud topics + service account
│   │   ├── postgres/               # CNPG PostgreSQL database/user
│   │   ├── dynamodb/               # DynamoDB tables
│   │   ├── mongodb_cluster/        # Mongo Atlas cluster (rare; usually shared)
│   │   ├── role/                   # App IAM role + trust policy
│   │   └── ...
│   └── apps/
│       ├── api/                    # REST API — Helm chart wrapper
│       ├── handler/                # Event handler (Kafka consumer)
│       ├── cron/                   # CronJob
│       └── ui/                     # Frontend
├── schemas/                         # JSON schemas for spec.yaml validation
└── README.md
```

**Module count:** ~40+ modules across common, infrastructure, apps.

**Important:** terraform-variant-apps is **invoked by mage-runner per module**, not as one big plan. Mage-runner picks which modules to run based on spec.yaml content (if `infrastructure.kafka` exists, run kafka; if not, skip).

---

## Section 2 — Module deep-dive (20 min)

Walk through each module. For each, give: purpose, key inputs, what it creates, fork-relevant changes.

### 2.1 — common/namespace

**Purpose:** Create the K8s namespace for the app.
**Key inputs:** namespace name, labels.
**What it creates:** `kubernetes_namespace` resource.
**Fork-relevant:** mage-runner *also* tries to create the namespace via the K8s SDK before TF runs. Belt and suspenders. Fork removes ambient labels in mage-runner namespace.go (Session 4).

### 2.2 — common/replicator

**Purpose:** Create a K8s ConfigMap recording deployment metadata (name, image, version, repo, user). Flux uses it as a breadcrumb for reconciliation drift detection.
**Key inputs:** spec.yaml top-level metadata.
**What it creates:** `kubernetes_config_map` named `<app>-iaac-replicator` in the app namespace.

### 2.3 — common/eks-data ⭐ critical

**Purpose:** Reads cluster endpoint, OIDC issuer, certificate authority. Other modules consume these outputs.

**Original (cloud) code:**
```hcl
data "aws_eks_cluster" "cluster" {
  name = var.cluster_name
}

output "endpoint"    { value = data.aws_eks_cluster.cluster.endpoint }
output "oidc_issuer" { value = data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer }
output "certificate_authority" { value = data.aws_eks_cluster.cluster.certificate_authority[0].data }
```

**Why it's a bottleneck:** every other module consumes these outputs. If you can't call `aws_eks_cluster`, the whole platform doesn't work.

**On-prem (fork) approach:** SSM fallback. When `var.use_eks_api == false`, read from SSM parameter store:
- `/clusters/<cluster_name>/endpoint`
- `/clusters/<cluster_name>/oidc-issuer`
- `/clusters/<cluster_name>/ca`

Conditional logic:
```hcl
locals {
  use_eks_api = var.use_eks_api  # Default true (cloud); false on-prem
}

data "aws_eks_cluster" "cluster" {
  count = local.use_eks_api ? 1 : 0
  name  = var.cluster_name
}

data "aws_ssm_parameter" "endpoint" {
  count = local.use_eks_api ? 0 : 1
  name  = "/clusters/${var.cluster_name}/endpoint"
}

# ...similar for oidc-issuer, ca

output "endpoint" {
  value = local.use_eks_api ? data.aws_eks_cluster.cluster[0].endpoint : data.aws_ssm_parameter.endpoint[0].value
}
```

This is the SSM eks-data fallback (INFRA-1446). Status: end-to-end green 2026-04-08; 12 callers patched; PR held per user direction. See [memory: ssm_eks_data_fallback_progress.md].

### 2.4 — common/auth

**Purpose:** Create an Azure AD app registration for the application.
**Key inputs:** scopes, redirect_uris, group_role_assignment, proxy config.
**What it creates:** `azuread_application`, `azuread_service_principal`, `azuread_application_password`. Outputs client_id, tenant_id, secret.
**Naming convention:** `dx-<env>-<space>-<app>` (e.g., `dx-dev-DevOps-brands-api`).

**Fork relevance:** This module is **stripped from on-prem deploys** (DX-Apply patched script removes `infrastructure.auth` from spec.yaml). Why: we reference the cloud-created Azure AD app via ExternalSecret, don't recreate.

### 2.5 — common/mongodb-user

**Purpose:** Create a Mongo Atlas database user with X.509 cert.
**Key inputs:** atlas project, cluster, role, db name.
**What it creates:** `mongodbatlas_database_user` + an X.509 cert. Writes the cert to a K8s Secret named `<app>-m-u`.
**Fork relevance (v2):** the on-prem fork has `terraform-mongodb-atlas-user` with a `use_eks_api` gate. When false, this submodule is skipped at the parent module level. Cloud creates the user; on-prem references the cert via cross-cluster ESO (POC) or AWS SM (prod path).

See [memory: onprem_mongo_atlas_v2_architectural.md].

### 2.6 — infrastructure/role

**Purpose:** Create an IAM role for the app, with trust policy bound to the app's K8s SA via OIDC.
**Key inputs:** app name, namespace, oidc_issuer (from eks-data), additional policy statements.
**What it creates:**
- `aws_iam_role` named `<env>-<app>` (e.g., `op-usxpress-dev-brands-api`)
- Trust policy:
  ```json
  {
    "Effect": "Allow",
    "Principal": {"Federated": "<oidc_provider_arn>"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "<oidc_issuer>:sub": "system:serviceaccount:<ns>:<sa_name>"
      }
    }
  }
  ```
- Inline policies from `var.iam.policy.statements` or `var.custom_policy.statements`.

**This is the IRSA setup per app.** The webhook reads the SA annotation `eks.amazonaws.com/role-arn` and injects creds.

### 2.7 — infrastructure/kafka

**Purpose:** Create Confluent Cloud topics + a service account for the app.
**Key inputs:** topic list with config (partitions, retention).
**What it creates:** `confluent_kafka_topic` resources, `confluent_service_account`, `confluent_api_key`. Writes credentials to K8s Secret `<app>-kafka-creds` and `<app>-kafka-reg-creds`.
**Fork relevance:** Confluent Cloud is external — works the same on-prem.

### 2.8 — infrastructure/postgres

**Purpose:** Create a database + user in CNPG PostgreSQL.
**Key inputs:** db name, role.
**Fork relevance:** if CNPG is deployed on the cluster (Talos has its own pattern; cloud uses RDS-CNPG), works on-prem.

### 2.9 — infrastructure/buckets, dynamodb

**Purpose:** Provision S3 buckets / DynamoDB tables. Standard AWS resources.
**Fork relevance:** None. Works the same on-prem since AWS is AWS.

### 2.10 — apps/api

**Purpose:** Deploy the app via Helm chart.
**Chart:** `064859874041.dkr.ecr.us-east-2.amazonaws.com/helm-charts/dx-api` (one chart per app type: api, cron, handler, ui).
**Key inputs:** image, version, port, env vars, configmaps, secrets, role_arn.
**What it creates:** `helm_release.app`. The chart provisions Deployment, Service, ServiceAccount with IRSA annotation, Istio VirtualService/Gateway.

**Fork relevance: extraSecrets injection.** When `use_eks_api == false`, the api module conditionally adds:

```hcl
locals {
  azuread_secret_name = "${var.spec.name}-azuread-secret"
}

resource "kubernetes_manifest" "extra_secrets" {
  count = var.use_eks_api ? 0 : 1
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.azuread_secret_name
      namespace = var.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = "default", kind = "ClusterSecretStore" }
      target          = { name = local.azuread_secret_name, creationPolicy = "Owner" }
      dataFrom = [{
        extract = { key = "azure-app-${var.env}-${var.space}-${var.spec.name}" }
      }]
    }
  }
}
```

And in the chart values, pass:
```hcl
chart_values = merge(base_values, var.use_eks_api ? {} : {
  extraSecrets = [local.azuread_secret_name]
})
```

The chart's `extraSecrets` is then mounted via envFrom on the pod.

This is the fork's core mechanism for "reference don't duplicate" — the Azure AD app exists in cloud, ExternalSecret pulls it from SM into a k8s secret on-prem, the pod mounts that secret.

See [memory: onprem_fork_extrasecrets_pattern.md].

---

## Section 3 — The fork gates summary (20 min)

There are 4 places `use_eks_api` matters. Drill these.

### Gate 1: eks-data SSM fallback
- Module: `modules/common/eks-data/`
- Behavior: when false, read cluster info from SSM instead of EKS API.
- Why: on-prem has no EKS API.

### Gate 2: api module extraSecrets injection
- Module: `modules/apps/api/`
- Behavior: when false, inject `<app>-azuread-secret` ExternalSecret + chart `extraSecrets`.
- Why: don't duplicate the cloud-created Azure AD app.

### Gate 3: mongodb_user submodule short-circuit
- Module: `modules/common/mongodb-user/` (uses `terraform-mongodb-atlas-user`)
- Behavior: when false, skip user creation. Cloud creates; on-prem references via the ESO bridge.
- Why: avoid race condition where two TF runs (cloud + on-prem) both try to create the same user.

### Gate 4: DX-Apply spec.yaml stripping (this is in DX, not TF — covered Session 4)
- Behavior: when false, strip `infrastructure.auth` and `infrastructure.mongodb` from spec.yaml before mage runs.
- Why: tells mage to skip those submodules entirely.

**Mental model**: `use_eks_api=false` means **"this is on-prem, behave conservatively, reference shared resources"**.

---

## Section 4 — Walk brands-api end-to-end (10 min)

Open `variant-inc/brands-api/spec.yaml` in editor. Real spec, real walk.

```yaml
name: brands-api
octopus:
  space: DevOps
  group: brands

git:
  repository: brands-api
  user: ci-bot
  version: 1.1266
  image: 064859874041.dkr.ecr.us-east-2.amazonaws.com/usxpress/brands-api:1.1266
  language: go

tags:
  owner: enterprise
  team: enterprise
  purpose: api

infrastructure:
  auth:
    scopes: [api://brands-api/.default]
    redirect_uris: [/oauth2/callback]
    group_roles_assignment:
      - name: usx-technology
        roles: [admin, user]
  iam:
    policy:
      - effect: Allow
        actions: [s3:GetObject]
        resources: [arn:aws:s3:::brands-data/*]

api:
  service:
    targetPort: 8080
  configVars:
    LOG_LEVEL: info
  secretVars: []
```

### What runs cloud-side (use_eks_api=true)
1. **eks-data**: read cluster info from EKS API.
2. **namespace**: create `brands` namespace if not exists.
3. **role**: create IAM role `usxpress-dev-brands-api` with the S3 inline policy + IRSA trust.
4. **auth**: create Azure AD app `dx-dev-DevOps-brands-api` with the scopes + roles. Write client_id/secret to AWS SM at `azure-app-dev-DevOps-brands-api`.
5. **api**: deploy Helm chart with image, port 8080, IRSA SA, Istio routing.
6. **replicator**: ConfigMap with deploy metadata.

### What runs on-prem (use_eks_api=false)

DX-Apply preflight first **strips `infrastructure.auth`** from the spec. So mage sees:

```yaml
name: brands-api
infrastructure:
  iam:
    policy: [...]   # auth gone, iam stays
api: { ... }
```

Then:
1. **eks-data**: SSM fallback. Reads `/clusters/op-usxpress-dev/{endpoint, ca, oidc-issuer}`.
2. **namespace**: create `brands` ns.
3. **role**: create `op-usxpress-dev-brands-api` IAM role (same as cloud, different env).
4. **auth**: SKIPPED (stripped from spec).
5. **api**: deploy Helm chart. Because `use_eks_api=false`, also create:
   - ExternalSecret `brands-api-azuread-secret` pulling `azure-app-dev-DevOps-brands-api` from SM.
   - Pass `extraSecrets: [brands-api-azuread-secret]` in chart values.
6. **replicator**: same.

The pod ends up with the same env vars in both cases, but on-prem they came from a cloud-created secret.

---

## Section 5 — Hands-on (10 min)

### Exercise 1: predict
Pick a different app — `geoenrichment-sync-handler`. Open its spec.yaml. Have Idris predict:
- Which modules run cloud-side?
- Which modules run on-prem (after DX-Apply strips)?
- What ExternalSecrets get created on-prem?
- What's the IAM role name?

### Exercise 2: read the fork diff
- `cd terraform-variant-apps && git checkout feature/onprem-support`
- `git log main..HEAD --oneline` — show all on-prem commits.
- `git diff main..HEAD modules/apps/api/main.tf` — see the actual extraSecrets injection.

---

## Common pitfalls

- **"My app deploy on-prem says auth module failed."** Did DX-Apply strip `infrastructure.auth`? Check the SSM block ran. If `infrastructure.auth` is in the spec mage sees, mage will try to create an Azure AD app and fail (no credentials).
- **"My app pod can't read the azuread secret."** Three places to check: (1) ExternalSecret created, (2) SM secret exists with the expected key path, (3) pod has IRSA + ESO has IRSA, both can hit SM.
- **"Mongo cert isn't appearing on-prem."** Cross-cluster ESO bridge needs the cloud SA token to be valid. Check `bootstrap-onprem-token.sh` was run. Or migrate to AWS SM.
- **"My role module says no oidc_issuer."** eks-data didn't return one. Either EKS API failed (cloud) or SSM param missing (on-prem). Check `aws ssm get-parameter --name /clusters/op-usxpress-dev/oidc-issuer`.

---

## Homework before Session 4

1. Open the fork branch in terraform-variant-apps. Read every commit on `feature/onprem-support`.
2. Pick one cloud-deployed app (any). Open its spec.yaml. Predict the modules. Verify against `aws s3 ls s3://lazy-tf-state-65v583i6my68y6x9/USXpress/<app>/` to see which TF state files exist (each = a module that ran).
3. Read [memory: onprem_fork_extrasecrets_pattern.md] and [memory: onprem_mongo_atlas_v2_architectural.md].

---

## Reference cheat sheet

| Thing | Value |
|---|---|
| Repo | `variant-inc/terraform-variant-apps` |
| Fork branch | `feature/onprem-support` |
| Per-app TF state location | `s3://op-usxpress-dev-tfstate/<space>/<app>/<module>/terraform.tfstate` |
| `use_eks_api=false` impact | (1) eks-data SSM fallback, (2) extraSecrets injection in api, (3) mongo skip, (4) DX-Apply spec strip |
| Azure AD app naming | `dx-<env>-<space>-<app>` |
| AWS SM key for azuread | `azure-app-<env>-<space>-<app>` |
| App IAM role naming | `<cluster_name>-<app>` |
| Helm chart base | `064859874041.dkr.ecr.us-east-2.amazonaws.com/helm-charts/dx-{api,cron,handler,ui}` |

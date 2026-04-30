# `iaac-risingwave` Repo Structure & Build Guide

**Audience**: Idris Fagbemi (Phase 1 platform owner)
**Goal**: Build the `iaac-risingwave` repo locally now. Once the repo exists on `variant-inc`, push and let Flux take over. No wasted work — every manifest you write on your laptop becomes the repo's initial commit.

This is the **iaac-eks-style pattern**: own repo, own CI/CD, decoupled from DX / mage-runner / Octopus. RisingWave's release cadence and ownership are separate from app deploys. **The on-prem team owns this end-to-end** — no cross-team dependency.

---

## The two-phase workflow

### Phase A — Local-only (now)

You build the full directory tree on your laptop under `~/code/iaac-risingwave/` (or wherever you keep work). You install RW on the cluster manually (`helm install ...`, `kubectl apply -f ...`) using the same files that will eventually be in the repo. Nothing is wasted — the laptop install proves the manifests work; the manifests go into the repo verbatim.

### Phase B — Committed & Flux-managed

1. On-prem team creates `variant-inc/iaac-risingwave` (empty)
2. You `git init`, add origin, push your local tree as the initial commit
3. We add a `GitRepository` + `Kustomization` to `iaac-talos-flux-cluster` pointing at this repo
4. Flux reconciles it like everything else
5. You delete the manual install (operator + CR) — Flux re-creates them, idempotent
6. From that point, RW changes flow: edit YAML → PR → merge → Flux applies

---

## Full directory layout

```
iaac-risingwave/
├── README.md
├── .gitignore
├── Makefile
├── terraform/
│   ├── backend.tf
│   ├── versions.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── s3.tf
│   └── iam.tf
├── helm/
│   ├── operator-values.yaml
│   ├── risingwave-cr.yaml
│   └── postgres-values.yaml
├── manifests/
│   └── op-usxpress-dev/
│       ├── kustomization.yaml
│       ├── namespace.yaml
│       ├── helmrepositories.yaml
│       ├── serviceaccount.yaml
│       ├── pg-externalsecret.yaml
│       ├── postgres-helmrelease.yaml
│       ├── operator-helmrelease.yaml
│       ├── risingwave-cr.yaml
│       └── servicemonitor.yaml
├── docs/
│   ├── architecture.md
│   ├── runbook.md
│   └── decisions.md
└── .github/
    └── workflows/
        ├── tf-plan.yaml
        └── tf-apply.yaml
```

### What each top-level dir is for

- **`terraform/`** — AWS resources outside the cluster (S3 bucket, IAM role, IRSA trust). Already provisioned manually; we capture them as code so the next cluster reproduces them.
- **`helm/`** — Raw chart values for reference / `helm install` use. Same values get embedded inside HelmReleases under `manifests/`. Keeping a copy here makes it easy to debug with `helm template ...` outside Flux.
- **`manifests/<cluster-name>/`** — The Flux entry point. Each cluster gets its own subdir. Today only `op-usxpress-dev/`. When we add EKS later, add `usxpress-dev-eks/` next to it. Same pattern, different cluster-specific values.
- **`docs/`** — Architecture, runbook, decisions log. Read-first for anyone new.
- **`.github/workflows/`** — CI for Terraform plan/apply. Manifests don't need workflows; Flux applies them directly.

---

## File contents — the bits you write

### `README.md`

```markdown
# iaac-risingwave

RisingWave streaming-DB platform for USXpress. Operator-based deploy.

## Layout
- `terraform/` — S3 bucket + IAM (IRSA) for RisingWave state store
- `manifests/<cluster>/` — Flux-managed K8s manifests
- `helm/` — chart values reference
- `docs/` — architecture, runbook, decisions

## Phase ownership
- Phase 1 (this repo) — Platform & infrastructure: Idris Fagbemi
- Phase 2 (separate concern) — SQL pipelines / MVs / Kafka sources: Tim Preble

## Clusters
| Cluster | Status | Purpose |
|---|---|---|
| op-usxpress-dev | active | on-prem dev |
| usxpress-dev EKS | planned | future cloud target |

## Day-2 ops
See `docs/runbook.md`.
```

### `.gitignore`

```
.terraform/
.terraform.lock.hcl
*.tfstate
*.tfstate.backup
*.tfvars
!*.example.tfvars
.vscode/
.idea/
*.swp
.DS_Store
```

### `Makefile`

```makefile
CLUSTER ?= op-usxpress-dev

.PHONY: tf-init tf-plan tf-apply lint diff sync

tf-init:
	cd terraform && terraform init

tf-plan:
	cd terraform && terraform plan -var-file=$(CLUSTER).tfvars

tf-apply:
	cd terraform && terraform apply -var-file=$(CLUSTER).tfvars

lint:
	kubectl apply --dry-run=client -k manifests/$(CLUSTER)/

diff:
	kubectl diff -k manifests/$(CLUSTER)/ || true

sync:
	flux reconcile kustomization risingwave-platform --with-source
```

### `terraform/backend.tf`

```hcl
terraform {
  backend "s3" {
    bucket = "lazy-tf-state-65v583i6my68y6x9"
    key    = "iaac/risingwave/op-usxpress-dev.tfstate"
    region = "us-east-2"
  }
}
```

(Same state bucket as `iaac-talos`; different key. Region us-east-2.)

### `terraform/versions.tf`

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
}
```

### `terraform/variables.tf`

```hcl
variable "cluster_name"   { type = string }   # e.g. "op-usxpress-dev"
variable "region"         { type = string  default = "us-east-2" }
variable "aws_profile"    { type = string }   # e.g. "usx-dev"
variable "oidc_issuer"    { type = string }   # e.g. "d3a7wcnazdrd6p.cloudfront.net"
variable "namespace"      { type = string  default = "risingwave" }
variable "service_account"{ type = string  default = "risingwave" }
```

### `terraform/s3.tf`

```hcl
resource "aws_s3_bucket" "state" {
  bucket = "risingwave-state-${var.cluster_name}"

  tags = {
    purpose    = "risingwave-state-store"
    cluster    = var.cluster_name
    managed-by = "onprem-platform-team"
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

### `terraform/iam.tf`

```hcl
data "aws_caller_identity" "current" {}

locals {
  oidc_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${var.oidc_issuer}"
  sa_sub   = "system:serviceaccount:${var.namespace}:${var.service_account}"
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_issuer}:sub"
      values   = [local.sa_sub]
    }
  }
}

resource "aws_iam_role" "rw" {
  name               = "${var.cluster_name}-risingwave"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

data "aws_iam_policy_document" "s3_rw" {
  statement {
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.state.arn]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
}

resource "aws_iam_policy" "s3_rw" {
  name   = "${var.cluster_name}-risingwave-s3"
  policy = data.aws_iam_policy_document.s3_rw.json
}

resource "aws_iam_role_policy_attachment" "s3_rw" {
  role       = aws_iam_role.rw.name
  policy_arn = aws_iam_policy.s3_rw.arn
}
```

### `terraform/outputs.tf`

```hcl
output "iam_role_arn"       { value = aws_iam_role.rw.arn }
output "s3_bucket"          { value = aws_s3_bucket.state.id }
output "service_account_sub" { value = local.sa_sub }
```

### `terraform/op-usxpress-dev.tfvars`

```hcl
cluster_name = "op-usxpress-dev"
region       = "us-east-2"
aws_profile  = "usx-dev"
oidc_issuer  = "d3a7wcnazdrd6p.cloudfront.net"
```

> **Note**: The bucket and role already exist (Dare provisioned them). Run `terraform import` once to bring them under management — don't `terraform apply` blind.

```bash
cd terraform
terraform init
terraform import -var-file=op-usxpress-dev.tfvars aws_s3_bucket.state risingwave-state-op-usxpress-dev
terraform import -var-file=op-usxpress-dev.tfvars aws_iam_role.rw op-usxpress-dev-risingwave
terraform import -var-file=op-usxpress-dev.tfvars aws_iam_policy.s3_rw arn:aws:iam::700736442855:policy/op-usxpress-dev-risingwave-s3
terraform plan -var-file=op-usxpress-dev.tfvars   # should show no changes
```

---

## Manifests — what Flux will reconcile

### `manifests/op-usxpress-dev/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrepositories.yaml
  - serviceaccount.yaml
  - pg-externalsecret.yaml
  - postgres-helmrelease.yaml
  - operator-helmrelease.yaml
  - risingwave-cr.yaml
  - servicemonitor.yaml
```

### `manifests/op-usxpress-dev/namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: risingwave
  labels:
    purpose: streaming-db
    istio.io/dataplane-mode: ambient
---
apiVersion: v1
kind: Namespace
metadata:
  name: risingwave-operator-system
  labels:
    purpose: risingwave-operator
```

### `manifests/op-usxpress-dev/helmrepositories.yaml`

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: risingwavelabs
  namespace: risingwave
spec:
  interval: 1h
  url: https://risingwavelabs.github.io/helm-charts
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: bitnami
  namespace: risingwave
spec:
  interval: 1h
  url: https://charts.bitnami.com/bitnami
```

### `manifests/op-usxpress-dev/serviceaccount.yaml`

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: risingwave
  namespace: risingwave
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::700736442855:role/op-usxpress-dev-risingwave
```

> The SA name MUST be `risingwave` — the IAM trust policy is scoped to this exact `system:serviceaccount:risingwave:risingwave`. Renaming the SA breaks IRSA silently.

### `manifests/op-usxpress-dev/pg-externalsecret.yaml`

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: pg-credentials
  namespace: risingwave
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secretsmanager   # default cluster store
    kind: ClusterSecretStore
  target:
    name: pg-credentials
    creationPolicy: Owner
  data:
    - secretKey: username
      remoteRef:
        key: op-usxpress-dev/risingwave/postgres
        property: username
    - secretKey: password
      remoteRef:
        key: op-usxpress-dev/risingwave/postgres
        property: password
    - secretKey: postgres-password
      remoteRef:
        key: op-usxpress-dev/risingwave/postgres
        property: postgres-password
```

> Pre-create the SM secret manually:
> ```bash
> aws secretsmanager create-secret \
>   --name op-usxpress-dev/risingwave/postgres \
>   --secret-string '{"username":"risingwave","password":"<generate>","postgres-password":"<generate>"}' \
>   --region us-east-2 --profile usx-dev
> ```

### `manifests/op-usxpress-dev/postgres-helmrelease.yaml`

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: pg
  namespace: risingwave
spec:
  interval: 30m
  chart:
    spec:
      chart: postgresql
      version: "15.x.x"   # pin to actual minor when you install
      sourceRef:
        kind: HelmRepository
        name: bitnami
        namespace: risingwave
  values:
    auth:
      database: risingwave
      username: risingwave
      existingSecret: pg-credentials
      secretKeys:
        adminPasswordKey: postgres-password
        userPasswordKey: password
    primary:
      persistence:
        enabled: true
        size: 20Gi
      resources:
        requests: { cpu: 250m, memory: 512Mi }
        limits:   { cpu: 1,    memory: 2Gi }
```

### `manifests/op-usxpress-dev/operator-helmrelease.yaml`

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: risingwave-operator
  namespace: risingwave-operator-system
spec:
  interval: 30m
  chart:
    spec:
      chart: risingwave-operator
      version: "0.x.x"   # pin after first install
      sourceRef:
        kind: HelmRepository
        name: risingwavelabs
        namespace: risingwave
  install:
    crds: CreateReplace
    remediation: { retries: 3 }
  upgrade:
    crds: CreateReplace
    remediation: { retries: 3 }
  values: {}
```

### `manifests/op-usxpress-dev/risingwave-cr.yaml`

```yaml
apiVersion: risingwave.risingwavelabs.com/v1alpha1
kind: RisingWave
metadata:
  name: risingwave
  namespace: risingwave
spec:
  metaStore:
    postgres:
      host: pg-postgresql.risingwave.svc.cluster.local
      port: 5432
      database: risingwave
      credentials:
        secretName: pg-credentials
        usernameKeyRef: username
        passwordKeyRef: password
  stateStore:
    s3:
      bucket: risingwave-state-op-usxpress-dev
      region: us-east-2
      # No keys — IRSA via SA annotation
  components:
    meta:
      replicas: 1
      resources:
        requests: { cpu: 500m, memory: 512Mi }
        limits:   { cpu: 2,    memory: 4Gi }
    frontend:
      replicas: 2
      resources:
        requests: { cpu: 250m, memory: 512Mi }
        limits:   { cpu: 1,    memory: 2Gi }
    compute:
      replicas: 2
      resources:
        requests: { cpu: 1, memory: 4Gi }
        limits:   { cpu: 4, memory: 16Gi }
    compactor:
      replicas: 1
      resources:
        requests: { cpu: 500m, memory: 512Mi }
        limits:   { cpu: 2,    memory: 4Gi }
  serviceAccount: risingwave
```

> **CR schema caveat**: The exact field names depend on the operator version you install. Run `kubectl explain risingwave.spec` after the operator is installed and adjust. The structure above matches recent versions; pin the operator chart and lock the schema.

### `manifests/op-usxpress-dev/servicemonitor.yaml`

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: risingwave
  namespace: risingwave
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      risingwave/name: risingwave
  endpoints:
    - port: metrics
      interval: 30s
  namespaceSelector:
    matchNames:
      - risingwave
```

> Confirm the metrics port name from the operator's docs — it's `metrics` on most versions.

---

## How Flux picks up this repo

This repo doesn't auto-deploy on its own. We wire it in via **`iaac-talos-flux-cluster`** (the cluster-level Flux repo). Add this to the cluster's flux directory:

`iaac-talos-flux-cluster/clusters/op-usxpress-dev/risingwave.yaml`:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: iaac-risingwave
  namespace: flux-system
spec:
  interval: 1m
  url: https://github.com/variant-inc/iaac-risingwave
  ref:
    branch: main
  secretRef:
    name: github-deploy-key   # already exists in flux-system
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: risingwave-platform
  namespace: flux-system
spec:
  interval: 5m
  path: ./manifests/op-usxpress-dev
  prune: true
  sourceRef:
    kind: GitRepository
    name: iaac-risingwave
  dependsOn:
    - name: cert-manager           # operator webhook needs it
    - name: external-secrets       # pg-credentials ExternalSecret
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: risingwave-operator
      namespace: risingwave-operator-system
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: pg
      namespace: risingwave
```

This is a Dare-side change. You don't need to do it — just know it's the wiring point.

---

## Working order — laptop today

1. **Create the dir tree** — make all the empty files first, then fill them in. `mkdir -p iaac-risingwave/{terraform,helm,manifests/op-usxpress-dev,docs,.github/workflows}`
2. **Write the manifests** — copy from this guide. Save in `manifests/op-usxpress-dev/`.
3. **Pre-create the SM secret** for Postgres credentials (snippet above).
4. **Apply by hand**, in order, against the cluster:
   ```bash
   kubectl apply -f manifests/op-usxpress-dev/namespace.yaml
   kubectl apply -f manifests/op-usxpress-dev/helmrepositories.yaml   # only matters once Flux owns them; safe to skip for laptop install
   kubectl apply -f manifests/op-usxpress-dev/serviceaccount.yaml
   kubectl apply -f manifests/op-usxpress-dev/pg-externalsecret.yaml
   # Wait for ExternalSecret → Secret to materialize
   kubectl get secret pg-credentials -n risingwave -o yaml
   helm install pg bitnami/postgresql -n risingwave -f helm/postgres-values.yaml
   helm install risingwave-operator risingwavelabs/risingwave-operator -n risingwave-operator-system --create-namespace
   kubectl apply -f manifests/op-usxpress-dev/risingwave-cr.yaml
   kubectl apply -f manifests/op-usxpress-dev/servicemonitor.yaml
   ```
5. **Verify**:
   - All pods `Running` — `kubectl get pods -n risingwave`
   - **psql** via port-forward — `kubectl -n risingwave port-forward svc/risingwave-frontend 4567:4567` then `psql -h localhost -p 4567 -d dev -U root` (operator default port is **4567**, not 4566)
   - **IRSA** — RW images don't include `aws` CLI, so verify two ways: (a) env-var inspection — `kubectl exec -n risingwave statefulset/risingwave-compute -- env | grep AWS_` should show `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`, `AWS_REGION`; (b) debug pod — `kubectl run aws-debug -n risingwave --rm -it --restart=Never --image=amazon/aws-cli:latest --overrides='{"spec":{"serviceAccountName":"risingwave"}}' -- s3 ls s3://risingwave-state-op-usxpress-dev/`
   - **Metrics** — `kubectl -n risingwave port-forward svc/risingwave-meta 1250:1250` then `curl localhost:1250/metrics | head`
6. **Iterate** the manifests until everything is healthy. Every fix to a YAML file = the laptop install matches the repo content.

---

## Working order — once the repo exists

1. On-prem team creates `variant-inc/iaac-risingwave` (empty).
2. From your laptop:
   ```bash
   cd ~/code/iaac-risingwave
   git init -b main
   git add .
   git commit -m "initial: RW operator + CR + Postgres metadata + IRSA TF"
   git remote add origin git@github.com:variant-inc/iaac-risingwave.git
   git push -u origin main
   ```
3. Dare adds the `GitRepository` + `Kustomization` to `iaac-talos-flux-cluster`.
4. Flux reconciles. Watch `flux get kustomizations`.
5. Delete the manual `helm install` releases — Flux re-creates them as HelmReleases. Idempotent if the chart versions match.
6. Tag the first stable commit: `git tag v0.1.0 && git push origin v0.1.0`.

---

## CI/CD outline (Phase B+)

Two workflows in `.github/workflows/`:

- **`tf-plan.yaml`** — runs on PRs touching `terraform/`. `terraform plan -var-file=$CLUSTER.tfvars`, posts plan as PR comment.
- **`tf-apply.yaml`** — runs on merge to `main`, manual `workflow_dispatch`. Auth via OIDC to USX-Dev.

Manifests don't need workflows — Flux applies them. Optionally add a `kubeval`/`kustomize build` lint workflow for PR validation.

---

## Things to NOT do

- **Don't put any of this in `iaac-talos-flux-platform`.** That repo is for app workloads (mage-runner deploys). RW is platform-not-app, owned separately.
- **Don't commit `*.tfvars` with secrets.** The `op-usxpress-dev.tfvars` shown above has no secrets — keep it that way.
- **Don't bypass IRSA** with hardcoded AWS keys in the RW CR. The strict trust policy on the IAM role won't allow it anyway, but: don't.
- **Don't change the SA name.** `risingwave` in namespace `risingwave`. The IAM trust scopes to that exact pair.
- **Don't apply the `iaac-talos-flux-cluster` GitRepository wiring yourself.** That's a Dare PR — flux-cluster is the cluster-team source of truth.

---

## Day-1 commit checklist (for first push)

- [ ] `README.md` populated
- [ ] `.gitignore` excludes `.terraform/`, state files, IDE clutter
- [ ] `terraform/` files match the live AWS resources (verified via `terraform plan` showing no changes)
- [ ] `manifests/op-usxpress-dev/*.yaml` matches what's running on the cluster
- [ ] `helm/*.yaml` reference values match HelmRelease values
- [ ] `docs/runbook.md` has at least: how to scale, how to upgrade operator, how to dump state
- [ ] No secrets in any committed file
- [ ] `kubectl apply --dry-run=client -k manifests/op-usxpress-dev/` passes

---

## Open questions to resolve with Tim

- Operator chart **version pin** — Tim may have preference based on POC experience
- **Resource sizing** for compute nodes — depends on Phase 2 workload
- **S3 lifecycle policy** — retention strategy on state-store objects (defer to Tim)
- **ServiceMonitor port name** — confirm against operator chart docs
- **PVC class** for Postgres — `gp3` if EBS available; on-prem may use a different StorageClass

---

## References

- RW operator chart: https://github.com/risingwavelabs/helm-charts/tree/main/charts/risingwave-operator
- Operator API docs: https://docs.risingwave.com/cloud/manage-risingwave-operator/
- Bitnami Postgres: https://github.com/bitnami/charts/tree/main/bitnami/postgresql
- Flux HelmRelease: https://fluxcd.io/flux/components/helm/helmreleases/
- iaac-eks (the analog repo to reference): https://github.com/variant-inc/iaac-eks

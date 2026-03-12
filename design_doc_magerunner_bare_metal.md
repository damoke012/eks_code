# Design Document: MageRunner Support for On-Premises Kubernetes

**Author:** Doke Oxley, Cloud Platform Team
**Reviewer:** Vibin Daniel, DX Team Lead
**Date:** March 12, 2026
**Status:** Draft — Awaiting Review

---

## 1. Executive Summary

This document proposes extending the DX MageRunner CI/CD pipeline to support on-premises bare-metal Kubernetes clusters running Talos Linux. The solution requires **2 code changes** (totaling ~16 lines) and **Octopus UI configuration**. Zero changes to developer workflow, Helm charts, spec.yaml format, or any Terraform module except `eks-data`.

The first target cluster is `op-usxpress-dev` (on-prem mirror of cloud `usxpress-dev`), deployed on 8 bare-metal nodes at Knight-Swift's datacenter.

---

## 2. Problem Statement

MageRunner's Terraform pipeline is tightly coupled to AWS EKS through the `eks-data` module:

```
modules/common/eks-data/main.tf
  └── data "aws_eks_cluster" → endpoint, oidc_issuer, certificate_authority
```

Every infrastructure module (replicator, role, auth, buckets, kafka, apps) depends on `eks-data`. On non-EKS clusters, `data.aws_eks_cluster` fails because there is no EKS cluster to query.

**Goal:** Enable MageRunner to deploy to on-prem clusters with the same developer experience as cloud — push code, GHA builds, Octopus deploys, MageRunner runs, app runs.

---

## 3. System Architecture

### 3.1 High-Level Component Layout

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           DEVELOPER WORKFLOW                                │
│                                                                             │
│  Developer → git push → GitHub Actions → Build/Test/Scan → ECR Push        │
│                              │                                              │
│                              ▼                                              │
│                     GitHub Actions Octopus                                  │
│                     (MageRunner CI mode)                                    │
│                              │                                              │
│              ┌───────────────┴───────────────┐                              │
│              ▼                               ▼                              │
│     ┌─────────────────┐            ┌─────────────────┐                     │
│     │  Octopus Space:  │            │  Octopus Space:  │                    │
│     │    USXpress      │            │    OnPremise     │                    │
│     │  (cloud envs)    │            │  (on-prem envs)  │                    │
│     └────────┬─────────┘            └────────┬─────────┘                   │
│              │                               │                              │
│              ▼                               ▼                              │
│     ┌─────────────────┐            ┌─────────────────┐                     │
│     │ Octopus Workers  │            │  Same Workers    │                    │
│     │ (EKS-hosted)     │────────────│  dual kubeconfig │                   │
│     └────────┬─────────┘            └────────┬─────────┘                   │
│              │                               │                              │
│              ▼                               ▼                              │
│     ┌─────────────────┐            ┌─────────────────────────┐             │
│     │   EKS Clusters   │            │  On-Prem Talos Clusters  │            │
│     │  usxpress-dev    │            │  op-usxpress-dev         │            │
│     │  qa-one          │            │  op-usxpress-qa  (future)│            │
│     │  usxpress-prod   │            │  op-usxpress-prod(future)│            │
│     └─────────────────┘            └─────────────────────────┘             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 MageRunner Pipeline Flow (Unchanged)

```
MageRunner CD Mode (Octopus Worker)
│
├── Stage 1-3: Setup
│   ├── Load spec.yaml + variables
│   ├── Clone terraform-variant-apps
│   └── Generate tfvars from Octopus variables
│
├── Stage 4-10: TfInfra (Terraform)
│   ├── tags          ─┐
│   ├── namespace      │
│   ├── replicator     │── All call module "eks_data"
│   ├── role           │   (mock returns static values
│   ├── auth (AzureAD) │    for on-prem clusters)
│   ├── buckets        │
│   ├── kafka          │
│   ├── dynamodb       │
│   ├── mongodb       ─┘
│   └── Each module gets: endpoint, oidc_issuer, certificate_authority
│
├── Stage 11-12: TfApps (Helm)
│   ├── dx-api chart release
│   ├── Creates: Deployment, Service, ServiceAccount
│   ├── Creates: ConfigMap ({app}-chart)
│   ├── Creates: ExternalSecret → AWS Secrets Manager
│   └── Sets: IRSA annotation on ServiceAccount
│
└── Result: App running on target cluster
```

### 3.3 Mock eks-data Decision Flow

```
                    ┌─────────────────┐
                    │  cluster_name   │
                    │  (from tfvars)  │
                    └────────┬────────┘
                             │
                             ▼
                   ┌─────────────────────┐
                   │ Is cluster_name in  │
                   │ mock_clusters map?  │
                   └──────┬──────┬───────┘
                          │      │
                    YES   │      │  NO
                          ▼      ▼
              ┌──────────────┐  ┌──────────────────┐
              │ Return static│  │ Call AWS EKS API  │
              │ values from  │  │ (existing behavior│
              │ mock map     │  │  unchanged)       │
              └──────┬───────┘  └────────┬──────────┘
                     │                   │
                     ▼                   ▼
              ┌─────────────────────────────────┐
              │  Same outputs:                   │
              │  • endpoint                      │
              │  • oidc_issuer                   │
              │  • certificate_authority          │
              └─────────────────────────────────┘
              │
              ▼
         All downstream modules work unchanged
```

### 3.4 IRSA Architecture (On-Prem vs Cloud)

```
Cloud EKS:                          On-Prem (op-usxpress-dev):
┌──────────────┐                    ┌──────────────────────┐
│ EKS manages  │                    │ Talos manages        │
│ OIDC keypair │                    │ SA signing keypair   │
└──────┬───────┘                    └──────────┬───────────┘
       │                                       │
       ▼                                       ▼
┌──────────────┐                    ┌──────────────────────┐
│ EKS OIDC     │                    │ Public keys hosted   │
│ endpoint     │                    │ on S3 + CloudFront   │
│ (AWS-managed)│                    │ d2vt9kpivked44.cf.net│
└──────┬───────┘                    └──────────┬───────────┘
       │                                       │
       ▼                                       ▼
┌──────────────┐                    ┌──────────────────────┐
│ IAM OIDC     │                    │ IAM OIDC Provider    │
│ Provider     │                    │ (Playground account) │
│ (EKS account)│                    │ (786352483360)       │
└──────┬───────┘                    └──────────┬───────────┘
       │                                       │
       ▼                                       ▼
┌──────────────────────────────────────────────────────────┐
│              Same IAM Trust Policy:                       │
│  "Federated": "arn:aws:iam::{account}:oidc-provider/..." │
│  "Condition": { "sub": "system:serviceaccount:ns:sa" }   │
└──────────────────────────┬───────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────┐
│              Same Pod Environment:                        │
│  AWS_ROLE_ARN=arn:aws:iam::786352483360:role/...         │
│  AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/...        │
└──────────────────────────────────────────────────────────┘

Injection:
  Cloud:   EKS Pod Identity Agent (daemonset)
  On-Prem: Pod Identity Webhook (mutating admission)
  Result:  IDENTICAL env vars + token mount
```

---

## 4. Detailed Design

### 4.1 Code Change #1: Mock eks-data Module

**Repository:** `terraform-variant-apps`
**Branch:** `feature/onprem-support`
**File:** `modules/common/eks-data/main.tf`

**Current:**
```hcl
data "aws_eks_cluster" "cluster" {
  name = var.cluster_name
}

output "endpoint" {
  value = data.aws_eks_cluster.cluster.endpoint
}

output "oidc_issuer" {
  value = data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer
}

output "certificate_authority" {
  value = data.aws_eks_cluster.cluster.certificate_authority[0].data
}
```

**Proposed:**
```hcl
variable "cluster_name" {
  type = string
}

# Static cluster data for non-EKS clusters (on-prem Talos)
locals {
  mock_clusters = {
    "op-usxpress-dev" = {
      endpoint                   = "https://10.10.82.30:6443"
      certificate_authority_data = "<base64 CA from kubeconfig>"
      oidc_issuer                = "https://d2vt9kpivked44.cloudfront.net"
    }
    # Future: "op-usxpress-qa", "op-usxpress-prod"
  }
  is_mock = contains(keys(local.mock_clusters), var.cluster_name)
}

# Only query EKS API for real EKS clusters
data "aws_eks_cluster" "cluster" {
  count = local.is_mock ? 0 : 1
  name  = var.cluster_name
}

output "endpoint" {
  value = local.is_mock ? local.mock_clusters[var.cluster_name].endpoint : data.aws_eks_cluster.cluster[0].endpoint
}

output "oidc_issuer" {
  value = local.is_mock ? local.mock_clusters[var.cluster_name].oidc_issuer : data.aws_eks_cluster.cluster[0].identity[0].oidc[0].issuer
}

output "certificate_authority" {
  value = local.is_mock ? local.mock_clusters[var.cluster_name].certificate_authority_data : data.aws_eks_cluster.cluster[0].certificate_authority[0].data
}
```

**Design rationale:**
- Keeps module name `eks-data` — no source path changes in any consuming module
- Keeps output names identical — no downstream changes
- Uses `count` conditional — standard Terraform pattern for optional resources
- Map-based lookup — easy to add future on-prem clusters (qa, prod)
- Cloud pipelines are unaffected — non-matching cluster names fall through to EKS API

**Validated:** Tested in MageRunner v17 local run — all 12 pipeline stages passed, pod deployed successfully.

### 4.2 Code Change #2: Environment Gate

**Repository:** `mage-runner`
**Branch:** `feature/onprem-support`
**File:** `cmd/mage/magefiles/terraform.go` line 37

```go
// Current:
[]string{"dpl", "devops", "development", "qa"}

// Proposed:
[]string{"dpl", "devops", "development", "qa", "dev"}
```

**Why:** MageRunner validates that `env_short` is in this allowlist before running Terraform. On-prem uses `dev` as the app-level environment name (per Vibin's guidance: "app deployments should go to dev, qa, stage and prod"). Note: `dpl2` was added locally for testing but is not in upstream.

### 4.3 Octopus Space Configuration

Per Vibin's decision: **separate Octopus Space** for on-prem deployments.

**Space:** `OnPremise` (already exists in Octopus)

The OnPremise space has 11 DX variable sets that mirror the cloud USXpress space, with environment-scoped overrides for on-prem values:

#### Variables Changed (Cloud → On-Prem Dev)

```
Variable Set     Variable                  Cloud Dev            OnPremise Dev
─────────────    ────────────────────────  ───────────────────  ─────────────────────
EKSCluster       CLUSTER_NAME              usxpress-dev         op-usxpress-dev
EKSCluster       CLUSTER_REGION            us-east-2            us-east-1
AWSAccounts      AWS_ACCOUNT_dev           700736442855         786352483360
AWSAccounts      AWS_REGION_dev            us-east-2            us-east-1
AWSAccessKeys    AWS_DEFAULT_REGION        us-east-2            us-east-1
AWSAccessKeys    AWS_IAM_PREFIX            usx-                 op-usxpress-dev
AWSAccessKeys    aws_resource_name_prefix  usx-                 op-usxpress-dev-
AWSAccessKeys    AWS_ROLE_TO_ASSUME        ...700736:octopus    ...786352:octopus
AWSAccessKeys    DOMAIN                    usxpress-dev.com     dev.usxpress.io
TFState          S3_BUCKET                 usxpress-dev-tfstate dpl2-local-test-tfstate
Tags             owner                     —                    cloud-platform
Tags             purpose                   —                    on-prem-dev
Tags             team                      —                    cloudops
```

> **AWS_ROLE_TO_ASSUME full values:**
> Cloud: `arn:aws:iam::700736442855:role/octopus-usxpress`
> OnPrem: `arn:aws:iam::786352483360:role/octopus-usxpress`

#### Variables Unchanged (Same for Cloud and On-Prem)

```
Variable Set          Why No Change
────────────────────  ──────────────────────────────────────────────────
DX_Common             env_short=dev, environment_abbreviation=dev (same)
DX_AzureAD            Same Azure AD tenant and service principal
DX_CCloud             Same Confluent Cloud Kafka cluster
DX_MongoDBAtlas       Same MongoDB Atlas organization
DX_Network            Same access control lists (monitor for IP issues)
DX_Runner             Same execution flags
ECR_ROLE_TO_ASSUME    ECR always from 064859874041 (infra-common)
```

### 4.4 IAM Role: octopus-usxpress in Playground

Created: `arn:aws:iam::786352483360:role/octopus-usxpress`

**Trust policy:** Allows assumption by any `iaac-octopus-worker-*` role in the AWS organization (`o-yza5l1xhrc`), plus explicit trust for `iaac-octopus-worker-usxpress-dev` in 700736442855.

**Permissions:** Identical to the cloud dev role — 19 inline policies (cloudwatch, dynamodb, ec2, ecr, elasticache, iam, kms, lambda, log, rds, rolesanywhere, route53_skip, s3, secretsmanager, security_group, security_group_skip, sns, ssm, sts) + AWS managed `ReadOnlyAccess`.

### 4.5 Worker Connectivity

Octopus workers run as pods on the EKS cluster (`usxpress-dev`). They reach the on-prem cluster via direct network path:

```
EKS Worker Pod → 10.10.82.30:6443 → Talos API Server
```

**Validated:** March 11, 2026 — `curl -sk https://10.10.82.30:6443/healthz` from worker pod returned 401 (TCP connectivity confirmed).

**Kubeconfig:** Standalone kubeconfig for `op-usxpress-dev` copied to `/etc/kubernetes/bm-dev-config` on each worker pod.

### 4.6 Terraform State

```
Resource              Account              Region     Value
────────────────────  ───────────────────  ─────────  ───────────────────────
S3 bucket             786352483360 (PG)    us-east-1  dpl2-local-test-tfstate
DynamoDB lock table   786352483360 (PG)    us-east-1  usxpress_tf_state
```

State is completely isolated from cloud environments.

### 4.7 Secret Architecture

```
┌─────────────────────────────────────────────────────┐
│              AWS Secrets Manager                     │
│                                                     │
│  Cloud Dev (700736442855, us-east-2):               │
│  ├── azure-app-dx-dev-usxpress-brands-api           │
│  ├── dx__enterprise-kafka-creds                     │
│  ├── dx--brands-api-mongo-creds                     │
│  └── ... (per-app secrets)                          │
│                    │                                 │
│                    │ copy (one-time)                 │
│                    ▼                                 │
│  Playground (786352483360, us-east-1):              │
│  ├── azure-app-dx-dev-usxpress-brands-api  (copy)   │
│  ├── dx__enterprise-kafka-creds            (copy)   │
│  ├── dx--brands-api-mongo-creds            (copy)   │
│  └── ... (same key names, isolated account)         │
└─────────────────────────────────────────────────────┘

ExternalSecret (on-prem cluster) → Playground SM → Real credentials
```

- **Same key names** as cloud dev — ExternalSecrets created by MageRunner work without modification
- **Isolated account** — zero risk to cloud dev secrets
- **Same shared services** — Confluent Cloud, MongoDB Atlas, Azure AD are external; same credentials work from on-prem

---

## 5. What Changes vs What Doesn't

### Changes (Total: 2 files, ~16 lines of code)

```
#  Component          Change                                Impact
─  ─────────────────  ────────────────────────────────────  ─────────
1  eks-data/main.tf   Add mock conditional map              ~15 lines
2  terraform.go:37    Add "dev" to env gate                 1 line
3  Octopus Space      Configure variable sets               UI only
4  IAM role           Create octopus-usxpress in Playground  One-time
5  Secrets Manager    Copy secrets from dev → playground     One-time
```

### No Changes Required

```
Component                    Why
───────────────────────────  ─────────────────────────────────────────────
GitHub Actions CI            Container images are cluster-agnostic
ECR repositories             Same ECR (064859874041) for all clusters
dx-api Helm chart            Chart is cluster-agnostic
spec.yaml format             No schema changes
All TF modules (except eks)  Reference module "eks_data" — outputs same
MageRunner variable pipeline cluster_name already flows through tfvars
Namespace creation           Already sets ambient + disabled labels
Kafka topics/users           Confluent Cloud is external
MongoDB Atlas                External service, same connection strings
Azure AD registrations       Same tenant
```

---

## 6. Naming Convention

```
Level                  Cloud          On-Prem          Pattern
─────────────────────  ─────────────  ───────────────  ──────────────────
Cluster name (TF/Oct)  usxpress-dev   op-usxpress-dev  op- prefix
App environment        dev            dev              Same
AWS resource prefix    usx-           op-usxpress-dev- Matches cluster name
Infra/VM prefix        —              bm-dev           Bare-metal infra only
Flux branch/folders    —              bm-dev           Bare-metal infra only
Octopus Space          USXpress       OnPremise        Separate space
```

**Future clusters:** `op-usxpress-qa`, `op-usxpress-staging`, `op-usxpress-prod`

---

## 7. Migration Plan

### Phase 1: Cluster Rebuild
- Tear down current `dpl2-cluster`, rebuild as `op-usxpress-dev`
- Refresh IRSA (new SA signing keypair → update S3/CloudFront/IAM OIDC provider)
- Bootstrap Flux with `bm-dev` cluster configs

### Phase 2: Fork & Code Changes
- Fork `terraform-variant-apps` → `feature/onprem-support`
- Fork `mage-runner` → `feature/onprem-support`
- Apply the 2 code changes described in sections 4.1 and 4.2
- Build MageRunner binary, test locally

### Phase 3: Infrastructure Setup
- Copy kubeconfig to Octopus workers
- Copy secrets from dev SM → Playground SM
- Octopus variable sets already configured (section 4.3)

### Phase 4: Validate Single App
- Deploy `brands-api` via Octopus → OnPremise space → dev environment
- Verify: pod running, ConfigMap, ExternalSecret synced, IRSA injected

### Phase 5: Deploy All Apps (3 Waves)
- Wave 1: Enterprise namespace (~15 apps)
- Wave 2: Trailers, geoservices, tasks, orders (25 apps)
- Wave 3: Remaining namespaces (~60 apps)

### Phase 6: Flux Cutover
- Remove Flux `app-deployments`, `app-configmaps`, `app-secrets` Kustomizations
- Keep Flux for infrastructure: cert-manager, istio, ESO, PIW, ECR creds, keda

---

## 8. Risk Assessment

```
Risk                          Impact              Likelihood  Mitigation
────────────────────────────  ──────────────────  ──────────  ──────────────────────────────
Network: EKS workers → onprem Deployments fail    Low         Health monitoring; onprem worker
TF state corruption           Lost state           Low         Dedicated S3 + DynamoDB locking
IRSA token validation failure Pods can't reach AWS Low         CloudFront OIDC validated; certs
Flux/MageRunner label conflict Namespace fights    Resolved    Fixed in v4-v6 (Flux labels removed)
Kafka consumer group collision Message stealing    Medium      Different group prefix per cluster
Mock map vs real EKS name     Cloud uses mock vals Very Low    op- prefix prevents name collision
```

---

## 9. Future Considerations

- **Additional on-prem clusters:** Add entries to `mock_clusters` map in `eks-data/main.tf`
- **On-prem worker pool:** If network reliability is a concern, deploy Octopus workers directly on on-prem cluster
- **Upstream PR:** Once validated, submit mock eks-data as upstream PR to terraform-variant-apps (not a permanent fork)
- **Automation:** Terraform module for Octopus Space variable set creation (currently manual via UI)

---

## 10. Questions for Reviewer

1. **Octopus Space name**: "OnPremise" — acceptable? (Already exists in Octopus)
2. **Consumer group prefix**: What should on-prem use to avoid collision with cloud dev?
3. **Fork strategy**: Same org feature branch, or separate fork?
4. **Upstream timeline**: When to submit mock eks-data as upstream PR to terraform-variant-apps?
5. **Environment expansion**: Timeline for on-prem QA and prod clusters?

---

## Appendix A: On-Prem Cluster Specifications

```
Property        Value
──────────────  ──────────────────────────────────────────────
Cluster Name    op-usxpress-dev
Distribution    Talos Linux v1.32.0
Kubernetes      v1.32.0
API Server      https://10.10.82.30:6443
Nodes           3 control plane + 5 worker
CNI             Cilium
Service Mesh    Istio (ambient mode)
OIDC Issuer     https://d2vt9kpivked44.cloudfront.net
Pod Identity    Pod Identity Webhook (2 replicas)
Secrets         External Secrets Operator → AWS SM (Playground)
GitOps          Flux CD (infrastructure only; apps via MageRunner)
AWS Account     786352483360 (Infrastructure-Playground)
AWS Region      us-east-1
```

## Appendix B: IRSA Comparison

```
Aspect            Cloud EKS                    On-Prem (op-usxpress-dev)
────────────────  ───────────────────────────  ──────────────────────────────
OIDC Provider     AWS-managed (EKS)            S3 + CloudFront
SA Token Signing  EKS-managed keypair          Talos-managed keypair
Token Injection   EKS Pod Identity Agent       Pod Identity Webhook
SA Annotation     eks.amazonaws.com/role-arn   Same
Pod Env Vars      AWS_ROLE_ARN + TOKEN_FILE    IDENTICAL
IAM Trust Policy  Federated OIDC provider      Same pattern, different issuer
```

## Appendix C: Octopus Variable Sets Reference

Full configuration details: `enterprise_procedure_onpremise_octopus_space.md`

```
Variable Set      Status      Notes
────────────────  ──────────  ──────────────────────────────────────────
DX_EKSCluster     Configured  CLUSTER_NAME=op-usxpress-dev (development)
DX_Common         No changes  Already correct for dev
DX_TFState        Configured  S3_BUCKET=dpl2-local-test-tfstate (dev)
DX_AWSAccounts    Configured  Account 786352483360, region us-east-1
DX_AWSAccessKeys  Configured  IAM prefix, role ARN, domain, region
DX_AzureAD        No changes  Same Azure AD tenant
DX_CCloud         No changes  Same Confluent Cloud
DX_MongoDBAtlas   No changes  Same Atlas org
DX_Network        No changes  Monitor for IP allowlist issues
DX_Runner         No changes  Same execution flags
DX_Tags           Configured  owner, purpose, team filled in
```

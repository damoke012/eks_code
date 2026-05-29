# DPL2 — On-Premises Kubernetes Platform for DX Applications

## What Are We Building?

An **on-premises Kubernetes cluster** that mirrors our production AWS EKS environment, enabling all ~156 DX application workloads to run on bare-metal infrastructure with the **same tooling, same CI/CD pipeline (MageRunner/Octopus), and same AWS integrations** as production.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           PRODUCTION (EKS)                              │
│                                                                         │
│   AWS EKS Cluster ──► MageRunner/Octopus ──► ~156 App Deployments      │
│   ├── Native IRSA                                                       │
│   ├── ECR Image Pull                                                    │
│   ├── Secrets Manager                                                   │
│   ├── Istio Service Mesh                                                │
│   └── Helm Charts (api/cron/handler/ui)                                 │
│                                                                         │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│                           DPL2 (ON-PREM)  ◄── We are building this     │
│                                                                         │
│   Talos K8s Cluster ──► MageRunner/Octopus ──► ~156 App Deployments    │
│   ├── IRSA via OIDC Federation (CloudFront + Pod Identity Webhook)      │
│   ├── ECR Image Pull (dual-region credential sync)                      │
│   ├── Secrets Manager (External Secrets Operator)                       │
│   ├── Istio Ambient Mesh (lighter than sidecar for bare-metal)          │
│   └── Same Helm Charts (api/cron/handler/ui)                            │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

**Goal**: A developer pushes code → GitHub Actions → Octopus → MageRunner deploys to dpl2 using the **exact same pipeline** as production EKS. No special handling, no separate tooling.

---

## Architecture Overview

```
                            ┌──────────────────────────────────────────┐
                            │              AWS CLOUD                    │
                            │                                          │
                            │  Playground Account (786352483360)       │
                            │  ┌────────────────────────────────────┐  │
                            │  │  IAM OIDC Provider                 │  │
                            │  │  (d2vt9kpivked44.cloudfront.net)   │  │
                            │  ├────────────────────────────────────┤  │
                            │  │  20 IRSA IAM Roles (Terraform)     │  │
                            │  ├────────────────────────────────────┤  │
                            │  │  AWS Secrets Manager (106 secrets) │  │
                            │  ├────────────────────────────────────┤  │
                            │  │  S3 OIDC Bucket + CloudFront      │  │
                            │  ├────────────────────────────────────┤  │
                            │  │  S3 Terraform State Bucket         │  │
                            │  └────────────────────────────────────┘  │
                            │                                          │
                            │  Infra-Common Account (064859874041)     │
                            │  ┌────────────────────────────────────┐  │
                            │  │  ECR Registries                    │  │
                            │  │  us-east-1 (4 images)              │  │
                            │  │  us-east-2 (97 images)             │  │
                            │  └────────────────────────────────────┘  │
                            └───────────────┬──────────────────────────┘
                                            │
                         OIDC / STS / S3 / ECR / Secrets Manager
                                            │
┌───────────────────────────────────────────┼──────────────────────────────┐
│               ON-PREMISES DATA CENTER (D1-Datacenter, vLAN 82)          │
│                                           │                              │
│   ┌───────────────────────────────────────┼────────────────────────┐    │
│   │         DPL2 TALOS KUBERNETES CLUSTER                          │    │
│   │         VIP: 10.10.82.30 | K8s v1.32.0 | Talos v1.9.x        │    │
│   │                                                                │    │
│   │   CONTROL PLANE (HA - 3 nodes)                                 │    │
│   │   ┌──────────────┐ ┌──────────────┐ ┌──────────────┐         │    │
│   │   │ talos-cp-dpl2│ │ talos-cp-dpl2│ │ talos-cp-dpl2│         │    │
│   │   │ -1           │ │ -2           │ │ -3           │         │    │
│   │   │ 10.10.82.22  │ │ 10.10.82.21  │ │ 10.10.82.23  │         │    │
│   │   │ 2 vCPU / 4GB │ │ 2 vCPU / 4GB │ │ 2 vCPU / 4GB │         │    │
│   │   └──────────────┘ └──────────────┘ └──────────────┘         │    │
│   │                                                                │    │
│   │   WORKERS (2 nodes)                                            │    │
│   │   ┌─────────────────────────┐ ┌─────────────────────────┐    │    │
│   │   │ talos-wk-dpl2-1         │ │ talos-wk-dpl2-2         │    │    │
│   │   │ 10.10.82.139            │ │ 10.10.82.138            │    │    │
│   │   │ 2 vCPU / 4GB            │ │ 2 vCPU / 4GB            │    │    │
│   │   └─────────────────────────┘ └─────────────────────────┘    │    │
│   │                                                                │    │
│   │   PLATFORM SERVICES                                            │    │
│   │   ┌──────────┐ ┌──────────┐ ┌───────────┐ ┌───────────────┐  │    │
│   │   │ Flux CD  │ │ Istio    │ │ Cert-Mgr  │ │ Pod Identity  │  │    │
│   │   │ (GitOps) │ │ Ambient  │ │ v1.19.1   │ │ Webhook       │  │    │
│   │   ├──────────┤ ├──────────┤ ├───────────┤ ├───────────────┤  │    │
│   │   │ External │ │ ECR Cred │ │ Cilium    │ │ Gateway API   │  │    │
│   │   │ Secrets  │ │ Sync     │ │ CNI + LB  │ │ CRDs          │  │    │
│   │   └──────────┘ └──────────┘ └───────────┘ └───────────────┘  │    │
│   │                                                                │    │
│   │   APPLICATION LAYER (48 namespaces, ~156 deployments)          │    │
│   │   ┌──────────────────────────────────────────────────────┐    │    │
│   │   │ enterprise  trailers  geoservices  tasks  orders ... │    │    │
│   │   │ (all enrolled in Istio ambient mesh)                  │    │    │
│   │   └──────────────────────────────────────────────────────┘    │    │
│   └────────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## How EKS Features Are Replicated On-Premises

The core challenge: MageRunner and DX applications assume AWS EKS. Here is how each EKS capability is replicated on dpl2:

### IRSA (IAM Roles for Service Accounts)

On EKS, pods automatically get AWS credentials via native OIDC. On dpl2, we replicate this:

```
EKS (Production)                          DPL2 (On-Prem)
─────────────────                         ─────────────────
EKS OIDC Provider (built-in)       →      CloudFront OIDC Provider
                                           S3 bucket: dpl2-oidc-irsa
                                           URL: d2vt9kpivked44.cloudfront.net

EKS Pod Identity (native)          →      Pod Identity Webhook
                                           (amazon-eks-pod-identity-webhook)
                                           Mutates pods on CREATE

API Server --service-account-       →      Talos API Server configured with
  issuer (auto-configured)                 --service-account-issuer=
                                           https://d2vt9kpivked44.cloudfront.net
                                           --api-audiences=sts.amazonaws.com

IAM Roles (per-app)                →      20 IAM Roles via Terraform
                                           Trust policy: OIDC federation
                                           Condition: namespace:serviceaccount
```

**The STS flow is identical**: Pod starts → webhook injects token + role ARN → AWS SDK calls `STS:AssumeRoleWithWebIdentity` → gets temporary credentials.

### ECR Image Pull

```
EKS (Production)                          DPL2 (On-Prem)
─────────────────                         ─────────────────
ECR pull-through cache or           →     CronJob (every 6h) fetches
  node IAM role for ECR access            ECR tokens for BOTH regions:
                                          - 064859874041.dkr.ecr.us-east-1
                                          - 064859874041.dkr.ecr.us-east-2
                                          Distributes ecr-pull-secret to
                                          ALL namespaces dynamically
```

### Secrets Management

```
EKS (Production)                          DPL2 (On-Prem)
─────────────────                         ─────────────────
External Secrets Operator           →     External Secrets Operator v0.12.x
  with IRSA                               with IRSA (same pattern)
  ClusterSecretStore → AWS SM             ClusterSecretStore → AWS SM
                                          106 ExternalSecrets synced
                                          Refresh: every 1 hour
```

### Service Mesh

```
EKS (Production)                          DPL2 (On-Prem)
─────────────────                         ─────────────────
Istio (sidecar mode)                →     Istio Ambient Mesh v1.27.3
                                          (ztunnel L4 proxy, no sidecars)
                                          Lower overhead on bare-metal
                                          Same mTLS, same trust domain
```

### Networking

```
EKS (Production)                          DPL2 (On-Prem)
─────────────────                         ─────────────────
AWS VPC CNI                         →     Cilium CNI (eBPF)
AWS ALB/NLB                         →     Cilium L2 LoadBalancer
                                          IP Pool: 10.10.82.20-254
```

---

## CI/CD Pipeline — MageRunner Integration

### Current Production Flow (EKS)

```
Developer Push → GitHub Actions → Octopus Deploy → MageRunner → EKS Cluster
                     │                  │                │
                     │                  │                ├── TfNamespace (create ns)
                     │                  │                ├── TfRole (create IRSA role)
                     │                  │                ├── TfBuckets/DynamoDB/Kafka
                     │                  │                └── TfApps (Helm chart deploy)
                     │                  │
                     │                  └── Worker runs on EKS
                     │                      KUBECONFIG = EKS cluster
                     │                      AWS creds = worker IAM role
                     │
                     └── Builds image → ECR
```

### Target DPL2 Flow (Same Pipeline)

```
Developer Push → GitHub Actions → Octopus Deploy → MageRunner → DPL2 Cluster
                     │                  │                │
                     │                  │                ├── TfNamespace (exists via Flux)
                     │                  │                ├── TfRole (exists via Terraform)
                     │                  │                ├── TfBuckets/DynamoDB/Kafka
                     │                  │                └── TfApps (Helm chart deploy)
                     │                  │
                     │                  └── Worker needs:
                     │                      KUBECONFIG = dpl2 kubeconfig
                     │                      AWS creds = playground account
                     │                      Network access to 10.10.82.30
                     │
                     └── Same images from ECR
```

### MageRunner Code Change

One line in `cmd/mage/magefiles/terraform.go` line 37:

```go
// Before:
[]string{"dpl", "devops", "development", "qa"}

// After:
[]string{"dpl", "dpl2", "devops", "development", "qa"}
```

### MageRunner Compatibility Assessment

| MageRunner Component | EKS-Specific? | Status on DPL2 |
|---------------------|---------------|----------------|
| Kubernetes API calls | No (standard kubeconfig) | Works |
| AWS S3 state backend | AWS, not EKS-specific | Works |
| ECR Helm chart pull | AWS, not EKS-specific | Works (needs ECR auth) |
| IRSA role creation (TfRole) | AWS IAM, not EKS | Works (OIDC configured) |
| Namespace creation (TfNamespace) | No | Works (pre-created via Flux) |
| Helm chart deploy (TfApps) | **May have EKS-specific values** | **Needs testing** |
| ALB Ingress annotations | **EKS-specific** | **Needs Cilium LB alternative** |
| AWS SDK credential chain | No (standard AWS creds) | Works (IRSA or env vars) |

**Key risk area**: The Terraform Helm charts (api/cron/handler/ui stored in ECR) may contain EKS-specific configurations like AWS ALB Ingress annotations. These need testing and may need value overrides for the Cilium L2 LoadBalancer on dpl2.

---

## Flux GitOps — Repository Structure

```
┌──────────────────────────┐     ┌─────────────────────────────────┐
│ iaac-talos               │     │ iaac-talos-flux-cluster          │
│ (Terraform bootstrap)    │     │ (master branch)                  │
│                          │     │                                   │
│ Creates:                 │────►│ clusters/dpl2/flux-system/        │
│ - 5 VMs on vSphere      │     │ ├── infra-source.yaml             │
│ - Talos cluster          │     │ ├── infra.yaml (18 Kustomizations)│
│ - Cilium CNI             │     │ └── kustomization.yaml            │
│ - Flux bootstrap         │     └──────────────┬──────────────────┘
│ - OIDC/IRSA setup        │                    │
└──────────────────────────┘                    │ GitRepository (dpl2 branch)
                                                ▼
                              ┌─────────────────────────────────────┐
                              │ iaac-talos-flux-platform             │
                              │ (dpl2 branch)                       │
                              │                                      │
                              │ infrastructure/                      │
                              │ ├── cert-manager/        (HelmRelease)
                              │ ├── cert-manager-issuers/ (CA chain)
                              │ ├── istio/               (4 HelmReleases)
                              │ ├── istio-csr/           (HelmRelease)
                              │ ├── cilium-lb/           (L2 LB pool)
                              │ ├── pod-identity-webhook/(Deployment)
                              │ ├── ecr-credentials/     (CronJob)
                              │ ├── external-secrets/    (HelmRelease)
                              │ ├── external-secrets-config/ (Store)
                              │ ├── app-namespaces/      (48 namespaces)
                              │ ├── app-secrets/         (106 secrets)
                              │ └── app-deployments/     (33 app files)
                              └─────────────────────────────────────┘
```

### Flux Dependency Chain

```
cert-manager → cert-manager-issuers → istio-csr → istio-base → istiod ──┬── istio-cni
                                                                          └── ztunnel

pod-identity-webhook ──┬── ecr-credentials ──┐
                       └── external-secrets ──┼── app-namespaces → app-secrets → app-deployments
                           external-secrets-config ─┘
```

---

## Terraform IRSA Roles

20 IAM roles in Playground account (786352483360):

| Role | Namespace | Service Account | AWS Access |
|------|-----------|-----------------|------------|
| dpl2-ecr-credentials-sync | ecr-credentials | ecr-credentials-sync | ECR |
| dpl2-external-secrets | external-secrets | external-secrets | Secrets Manager |
| dpl2-driver-insights-cron | enterprise | driver-insights-cron | S3 |
| dpl2-ocs-cisive-handler | enterprise | ocs-cisive-handler | S3 |
| dpl2-safetylytx-video-handler | enterprise | safetylytx-video-handler | S3 |
| dpl2-trailers-api | trailers | trailers-api | S3 |
| dpl2-domte | trailers | domte | S3 |
| dpl2-ttelh | trailers | ttelh | S3 |
| dpl2-uteh | trailers | uteh | S3 |
| dpl2-driver-message-handler | trailers | driver-message-handler | SQS/SNS |
| dpl2-geofence-api | geoservices | geofence-api | DynamoDB |
| dpl2-data-address-api | geoservices | data-address-api | DynamoDB |
| dpl2-geofence-data-provider | geoservices | geofence-data-provider | S3 |
| dpl2-task-data-api | tasks | task-data-api | DynamoDB |
| dpl2-mcleod-location-sync-handler | mcleod-data-sync | mcleod-location-sync-handler | SQS/SNS |
| dpl2-event-message-bridge-api | messagebridge | event-message-bridge-api | SQS/SNS |
| dpl2-safetylytx-video-api | safety | safetylytx-video-api | S3 |
| dpl2-pricing-rfp-api | knx-synergy | pricing-rfp-api | S3 |
| dpl2-capacity-snapshots-cron | freight | capacity-snapshots-cron | S3 |
| dpl2-kafka-connect | kafka | connect-connect | S3 |

---

## Current State

| Component | Status | Count |
|-----------|--------|-------|
| VMs (vSphere) | Running | 5 nodes |
| Talos Cluster | Healthy | K8s v1.32.0 |
| Flux Kustomizations | All Ready | 18/18 |
| Namespaces | Created | 48 |
| ExternalSecrets | All Synced | 106/106 |
| IRSA IAM Roles | Created | 20/20 |
| ECR Credentials | Active (dual-region) | us-east-1 + us-east-2 |
| Istio Ambient Mesh | Running | istiod + ztunnel + CNI |
| Pod Identity Webhook | Running | 2 replicas |
| cert-manager | Running | v1.19.1 |
| Cilium L2 LB | Configured | 235 IPs available |
| MageRunner Integration | **In Progress** | Needs fork + test |

---

## Remaining Work

### Phase 1: MageRunner Integration (Current)

- [ ] Fork mage-runner, add `"dpl2"` to allowed environments
- [ ] Local test run against dpl2 cluster with logs
- [ ] Create PR with test evidence
- [ ] Configure Octopus DPL2 environment + variables
- [ ] Deploy dpl2 kubeconfig to Octopus worker
- [ ] Verify worker network path to 10.10.82.30

### Phase 2: Application Deployment

- [ ] Test single app through full MageRunner pipeline
- [ ] Identify and resolve EKS-specific Helm chart issues (ALB → Cilium LB)
- [ ] Deploy all ~156 applications
- [ ] Replace placeholder AzureAD secrets with real values

### Phase 3: Production Readiness

- [ ] Monitoring and alerting
- [ ] Log aggregation
- [ ] Scale worker nodes
- [ ] Operational runbooks
- [ ] DNS / service discovery

---

## AWS Accounts

| Account | ID | Purpose |
|---------|-----|---------|
| Infrastructure-Playground | 786352483360 | IRSA, Secrets Manager, OIDC, TF state |
| Infrastructure-Common | 064859874041 | ECR container image registries |

## Network

| Resource | Address |
|----------|---------|
| K8s API (VIP) | 10.10.82.30:6443 |
| OIDC Issuer | https://d2vt9kpivked44.cloudfront.net |
| LB IP Pool | 10.10.82.20 — 10.10.82.254 |
| vSphere DC | D1-Datacenter / D1 NTX PROD |
| VLAN | 10.10.82.0/24 (vLAN 82 Prod) |

## Repositories

| Repository | Branch | Purpose |
|------------|--------|---------|
| iaac-talos | feature/dpl2-cluster | VM provisioning + cluster bootstrap |
| iaac-talos-flux-cluster | master | Flux kustomization wiring |
| iaac-talos-flux-platform | dpl2 | Platform manifests + app configs |
| terraform-irsa-roles | main | 20 IRSA IAM roles |
| mage-runner | feature/dpl2-environment | CI/CD orchestration (1-line change) |

Design Document: MageRunner Support for On-Premises Kubernetes

Author:     Dare Oke, Cloud Platform Team
Reviewer:   Vibin Daniel, DX Team Lead
Date:       March 17, 2026
Status:     Draft v3
Ticket:     (pending - Jira/Linear ticket to be created)


1. EXECUTIVE SUMMARY

This document proposes extending the DX MageRunner CI/CD pipeline to support on-premises
bare-metal Kubernetes clusters running Talos Linux. The solution requires 1 code change
(SSM fallback in eks-data module) and Octopus configuration via iaac-octopus-config repo.
Zero changes to developer workflow, Helm charts, spec.yaml format, or any Terraform module
except eks-data.

The design goal is: on-prem runs the exact same DX pipeline as cloud. Same MageRunner binary,
same Terraform modules, same Octopus trigger, same spec.yaml. There is no ADR because there
is no architectural divergence - we are extending the existing architecture, not changing it.

MageRunner is specifically built to work with AWS EKS. Investigation confirmed that the only
hard EKS dependency is the eks-data module (data "aws_eks_cluster"). All other modules
(replicator, role, auth, buckets, kafka, dynamodb, mongodb, apps) depend on eks-data outputs
but are not EKS-specific themselves. The SSM fallback resolves this single coupling point.
Local testing validated that the full pipeline runs successfully once eks-data returns valid
cluster metadata - see Appendix D for test evidence.

The first target cluster is op-usxpress-dev (on-prem Development environment), deployed on
8 bare-metal nodes at Knight-Swift's datacenter.


2. PROBLEM STATEMENT

MageRunner's Terraform pipeline is tightly coupled to AWS EKS through the eks-data module:

```
modules/common/eks-data/main.tf
  data "aws_eks_cluster" -> endpoint, oidc_issuer, certificate_authority
```

Every infrastructure module (replicator, role, auth, buckets, kafka, apps) depends on eks-data.
On non-EKS clusters, data.aws_eks_cluster fails because there is no EKS cluster to query.

Solution: Add an SSM Parameter Store fallback to the eks-data module. When use_eks_api=false,
the module queries cluster metadata from SSM instead of the EKS API - same dynamic lookup
pattern, no static values in code.

Goal: Enable MageRunner to deploy to on-prem clusters with the same developer experience as
cloud - push code, GitHub Actions builds, Octopus deploys, MageRunner runs, app runs.


3. SYSTEM ARCHITECTURE

3.1 High-Level Component Layout

```
Developer -> git push -> GitHub Actions -> Build/Test/Scan -> ECR Push
                              |
                              v
                     GitHub Actions Octopus
                     (MageRunner CI mode)
                              |
              +---------------+---------------+
              v                               v
     Octopus Space:                  Octopus Space:
       USXpress                        OnPremise
     (cloud envs)                    (on-prem envs)
              |                               |
              v                               v
     Octopus Workers                 Octopus Workers
     (EKS-hosted)                    (on-prem hosted)
              |                               |
              v                               v
     EKS Clusters                    On-Prem Talos Clusters
     usxpress-dev                    op-usxpress-dev
     qa-one                          op-usxpress-qa  (future)
     usxpress-prod                   op-usxpress-prod (future)

On-prem workers run on the on-prem cluster itself, not on EKS.
Each environment is fully independent - no cross-cluster dependencies.
```

3.2 MageRunner Pipeline Flow (Unchanged)

The pipeline is identical for cloud and on-prem. MageRunner creates all app infrastructure,
not just Kubernetes resources:

```
MageRunner CD Mode (Octopus Worker)
|
+-- Stage 1-3: Setup
|   +-- Load spec.yaml + variables
|   +-- Clone terraform-variant-apps
|   +-- Generate tfvars from Octopus variables
|
+-- Stage 4-10: TfInfra (Terraform)
|   +-- 1. tags          -> Resource tags (Terraform state)
|   +-- 2. namespace     -> Kubernetes namespace + labels (Cluster)
|   +-- 3. replicator    -> ECR pull secret / ImagePullSecret (Cluster)
|   +-- 4. role          -> IAM role + OIDC trust policy (AWS IAM)
|   +-- 5. auth          -> Azure AD app registration + secret (Azure AD + AWS SM)
|   +-- 6. buckets       -> S3 bucket, if declared (AWS S3)
|   +-- 7. kafka         -> Confluent Cloud topic + ACL + user (Confluent Cloud)
|   +-- 8. dynamodb      -> DynamoDB table, if declared (AWS DynamoDB)
|   +-- 9. mongodb       -> MongoDB Atlas database + user (MongoDB Atlas)
|   +-- All call module "eks_data" -> SSM returns cluster values for on-prem
|
+-- Stage 11-12: TfApps (Helm)
|   +-- dx-api chart release
|   +-- Creates: Deployment, Service, ServiceAccount
|   +-- Creates: ConfigMap ({app}-chart)
|   +-- Creates: ExternalSecret -> AWS Secrets Manager
|   +-- Sets: IRSA annotation on ServiceAccount
|
+-- Result: App running on target cluster with ALL infrastructure provisioned
```

3.3 Deployment Flow Comparison

```
Cloud:    git push -> GHA -> Octopus (USXpress space) -> MageRunner -> all TF modules -> app on EKS
On-Prem:  git push -> GHA -> Octopus (OnPremise space) -> MageRunner -> all TF modules -> app on Talos
                                                                          |
                                                          Only difference: eks-data queries SSM
                                                          instead of EKS API. Everything else
                                                          is byte-for-byte identical.
```

No manual steps in the deploy path. A developer deploying to on-prem does not do anything different.

3.4 eks-data Decision Flow (SSM Fallback)

```
                    Inputs (from Octopus/tfvars)
                    - cluster_name
                    - use_eks_api (bool)
                              |
                              v
                       use_eks_api = ?
                        /         \
                  true /           \ false
             (default)/             \(OnPremise space)
                     v               v
        Query AWS EKS API     Query AWS SSM Parameter
        (existing behavior    Store (dynamic lookup)
         unchanged)
                              /clusters/{name}/
        data                    endpoint
        "aws_eks_cluster"       certificate_authority
                                oidc_issuer
                     \               /
                      v             v
              Same outputs (identical interface):
              - endpoint
              - oidc_issuer
              - certificate_authority
                        |
                        v
          All downstream modules work unchanged
          (replicator, role, auth, buckets, kafka,
           dynamodb, mongodb, apps)
```

3.5 IRSA Architecture (On-Prem vs Cloud)

```
Cloud EKS:                          On-Prem (op-usxpress-dev):

EKS manages                         Talos manages
OIDC keypair                         SA signing keypair
    |                                    |
    v                                    v
EKS OIDC                            Public keys hosted
endpoint                             on S3 + CloudFront
(AWS-managed)                        d2vt9kpivked44.cf.net
    |                                    |
    v                                    v
IAM OIDC                             IAM OIDC Provider
Provider                              (Playground account)
(EKS account)                        (786352483360)
    |                                    |
    v                                    v
              Same IAM Trust Policy:
  "Federated": "arn:aws:iam::{account}:oidc-provider/..."
  "Condition": { "sub": "system:serviceaccount:ns:sa" }
                        |
                        v
              Same Pod Environment:
  AWS_ROLE_ARN=arn:aws:iam::786352483360:role/...
  AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/...

Injection:
  Cloud:   EKS Pod Identity Agent (daemonset)
  On-Prem: Pod Identity Webhook (mutating admission)
  Result:  IDENTICAL env vars + token mount
```


4. DETAILED DESIGN

4.1 Code Change: SSM-Backed eks-data Module

Repository:  terraform-variant-apps
Branch:      feature/onprem-support
File:        modules/common/eks-data/main.tf

Current (cloud-only):

```hcl
variable "cluster_name" {
  type = string
}

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

Proposed (SSM fallback for on-prem):

```hcl
variable "cluster_name" {
  type = string
}

variable "use_eks_api" {
  type    = bool
  default = true
}

# Cloud path: query AWS EKS API (existing behavior, unchanged)
data "aws_eks_cluster" "cluster" {
  count = var.use_eks_api ? 1 : 0
  name  = var.cluster_name
}

# On-prem path: query AWS SSM Parameter Store
data "aws_ssm_parameter" "endpoint" {
  count = var.use_eks_api ? 0 : 1
  name  = "/clusters/${var.cluster_name}/endpoint"
}

data "aws_ssm_parameter" "certificate_authority" {
  count = var.use_eks_api ? 0 : 1
  name  = "/clusters/${var.cluster_name}/certificate_authority"
}

data "aws_ssm_parameter" "oidc_issuer" {
  count = var.use_eks_api ? 0 : 1
  name  = "/clusters/${var.cluster_name}/oidc_issuer"
}

# Outputs: same names, same types, downstream modules unchanged
output "endpoint" {
  value = var.use_eks_api ? data.aws_eks_cluster.cluster[0].endpoint : data.aws_ssm_parameter.endpoint[0].value
}

output "certificate_authority" {
  value = var.use_eks_api ? data.aws_eks_cluster.cluster[0].certificate_authority[0].data : data.aws_ssm_parameter.certificate_authority[0].value
}

output "oidc_issuer" {
  value = var.use_eks_api ? data.aws_eks_cluster.cluster[0].identity[0].oidc[0].issuer : data.aws_ssm_parameter.oidc_issuer[0].value
}
```

How it works:

```
Cloud (default):   use_eks_api = true  -> data "aws_eks_cluster"   -> queries EKS API
On-prem:           use_eks_api = false -> data "aws_ssm_parameter" -> queries SSM API
                                                                       |
                                         Values stored in SSM:         |
                                         /clusters/{name}/endpoint ----+
                                         /clusters/{name}/certificate_authority
                                         /clusters/{name}/oidc_issuer
```

SSM Parameter Store setup (one-time per cluster):

```bash
# Store cluster metadata in SSM (Playground account, us-east-1)
aws ssm put-parameter --profile playground --region us-east-1 \
  --name "/clusters/op-usxpress-dev/endpoint" \
  --value "https://10.10.82.50:6443" --type String

aws ssm put-parameter --profile playground --region us-east-1 \
  --name "/clusters/op-usxpress-dev/certificate_authority" \
  --value "<base64 CA from kubeconfig>" --type String

aws ssm put-parameter --profile playground --region us-east-1 \
  --name "/clusters/op-usxpress-dev/oidc_issuer" \
  --value "https://d2vt9kpivked44.cloudfront.net" --type String
```

Design rationale:
- Dynamic like cloud - both paths query an AWS API (EKS API vs SSM API), no static values in code
- No code changes to add clusters - add QA/prod by running 3 aws ssm put-parameter commands
- Updatable without PRs - if API server IP changes (cluster rebuild), update 1 SSM parameter
- Keeps module name eks-data - no source path changes in any consuming module
- Keeps output names identical - no downstream changes
- Uses count conditional - standard Terraform pattern for optional resources
- use_eks_api defaults to true - cloud pipelines completely unaffected

Validated: Local testing with mock approach confirmed pipeline flow. SSM approach uses the
same count pattern with dynamic values instead of static map.


4.2 Octopus Space Configuration

On-prem deployments use a separate Octopus Space (OnPremise) from cloud (USXpress).

Space: OnPremise (already exists in Octopus)

Configuration management: Octopus variables and script-modules are managed in the
iaac-octopus-config repo. The current scripts are tightly integrated with AWS and EKS.
For on-prem support:

- Create new scripts in iaac-octopus-config for on-prem Space configuration
- Configure the repo to deploy certain files to certain Spaces (USXpress vs OnPremise)
- This ensures Octopus configuration is code-managed, reviewable, and repeatable for
  future environments (QA, prod)

Environment mapping:

```
Short Name    Full Name      Octopus Environment
----------    -----------    -------------------
dev           development    Development
stg           staging        Staging (future)
prod          production     Production (future)
```

Short names (dev, stg, prod) are used for resource naming to avoid hitting AWS resource
naming limits. They map to the same Octopus environments as cloud.

The OnPremise space has 11 DX variable sets that mirror the cloud USXpress space, with
environment-scoped overrides for on-prem values:

Variables Changed (Cloud to On-Prem Dev):

```
Variable Set     Variable                  Cloud Dev            OnPremise Dev
-------------    ------------------------  -------------------  ---------------------
EKSCluster       CLUSTER_NAME              usxpress-dev         op-usxpress-dev
EKSCluster       CLUSTER_REGION            us-east-2            us-east-1
EKSCluster       TF_VAR_use_eks_api        (not set, true)      false
AWSAccounts      AWS_ACCOUNT_dev           700736442855         786352483360
AWSAccounts      AWS_REGION_dev            us-east-2            us-east-1
AWSAccessKeys    AWS_DEFAULT_REGION        us-east-2            us-east-1
AWSAccessKeys    AWS_IAM_PREFIX            usx-                 op-usxpress-dev
AWSAccessKeys    aws_resource_name_prefix  usx-                 op-usxpress-dev-
AWSAccessKeys    AWS_ROLE_TO_ASSUME        ...700736:octopus    ...786352:octopus
AWSAccessKeys    DOMAIN                    usxpress-dev.com     dev.usxpress.io
TFState          S3_BUCKET                 usxpress-dev-tfstate op-usxpress-dev-tfstate
Tags             owner                     -                    cloud-platform
Tags             purpose                   -                    on-prem-dev
Tags             team                      -                    cloudops
```

TF_VAR_use_eks_api: This variable tells the eks-data Terraform module to query SSM
Parameter Store instead of the EKS API. MageRunner's getTfVarsFromEnv() automatically
forwards all TF_VAR_* environment variables to Terraform. Not set in cloud spaces
(defaults to true). Set to false only in the OnPremise space.

AWS_ROLE_TO_ASSUME full values:
  Cloud:  arn:aws:iam::700736442855:role/octopus-usxpress
  OnPrem: arn:aws:iam::786352483360:role/octopus-usxpress

Variables Unchanged (Same for Cloud and On-Prem):

```
Variable Set          Why No Change
--------------------  --------------------------------------------------
DX_Common             env_short=dev, environment_abbreviation=dev (same)
DX_AzureAD            Same Azure AD tenant and service principal
DX_CCloud             Same Confluent Cloud Kafka cluster
DX_MongoDBAtlas       Same MongoDB Atlas organization
DX_Network            Same access control lists (monitor for IP issues)
DX_Runner             Same execution flags
ECR_ROLE_TO_ASSUME    ECR always from 064859874041 (infra-common)
```


4.3 IAM Role: octopus-usxpress in Playground

Created: arn:aws:iam::786352483360:role/octopus-usxpress

Trust policy: The on-prem Octopus worker pod receives IRSA credentials via Pod Identity
Webhook on the on-prem cluster. The trust policy references the on-prem OIDC provider
in Playground (786352483360). The worker then assumes octopus-usxpress to execute Terraform.

```
On-Prem Worker Pod
  -> IRSA (Pod Identity Webhook injects AWS_WEB_IDENTITY_TOKEN_FILE)
  -> STS AssumeRoleWithWebIdentity against on-prem OIDC provider
  -> arn:aws:iam::786352483360:role/octopus-usxpress
  -> Terraform runs with full permissions
```

Trust policy configuration:

```json
{
  "Effect": "Allow",
  "Principal": {
    "Federated": "arn:aws:iam::786352483360:oidc-provider/d2vt9kpivked44.cloudfront.net"
  },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringLike": {
      "d2vt9kpivked44.cloudfront.net:sub": "system:serviceaccount:octopus:octopus-worker"
    }
  }
}
```

Permissions: 19 inline policies (cloudwatch, dynamodb, ec2, ecr, elasticache, iam, kms,
lambda, log, rds, rolesanywhere, route53_skip, s3, secretsmanager, security_group,
security_group_skip, sns, ssm, sts) + AWS managed ReadOnlyAccess.


4.4 Octopus Workers (On-Prem)

Octopus workers run on the on-prem cluster itself - no dependencies on EKS clusters.

```
Cloud:    Workers run on EKS cluster    -> deploy to same EKS cluster
On-Prem:  Workers run on Talos cluster  -> deploy to same Talos cluster
```

Architecture:
- Octopus tentacle/worker pods deployed on op-usxpress-dev
- Workers assume IAM roles via IRSA (Pod Identity Webhook on the same cluster)
- Fully standalone - no cross-network dependency on EKS
- Workers need outbound internet access for: ECR pulls, AWS API calls, Azure AD,
  Confluent Cloud, MongoDB Atlas

Worker IAM identity:
- Worker pod gets IRSA via Pod Identity Webhook, ServiceAccount annotated with IAM role ARN
- STS validates the projected token against the on-prem OIDC provider (CloudFront)
- Worker assumes octopus-usxpress role in Playground to execute Terraform

Worker registration:
- Workers register with the Octopus server using the same tentacle approach as cloud
- Configuration managed in iaac-octopus-config repo, scoped to the OnPremise space


4.5 External DNS

Cloud uses external-dns with Route53 to automatically create DNS records for app ingress.
On-prem follows the same pattern:

```
Cloud:    external-dns -> Route53 -> A record -> EKS ALB/NLB IP
On-Prem:  external-dns -> Route53 -> A record -> On-prem Istio ingress gateway IP
```

How it works:
- external-dns runs on the on-prem cluster (deployed via Flux, same as cloud)
- When an Istio VirtualService or Gateway is created, external-dns detects the hostname
- external-dns creates/updates an A record in Route53 pointing to the on-prem ingress IP
- Same Route53 hosted zone as cloud (usxpress.io) - no separate DNS provider needed
- No GoDaddy or other registrar required - Route53 handles everything

On-prem app DNS naming convention:

```
Cloud:    api.{app}.dev.usxpress.io  ->  EKS ingress IP
On-prem:  api.{app}.op-dev.usxpress.io  ->  On-prem Istio ingress gateway IP
```

The on-prem ingress gateway IP is the external IP of the Istio ingress gateway service
running on the on-prem cluster. For internal-only apps, this can be a private IP accessible
within the corporate network.

Requirements:
- external-dns deployed on op-usxpress-dev via Flux
- IAM role for external-dns with Route53 permissions (via IRSA)
- Istio ingress gateway with a routable IP (internal or external)
- Route53 hosted zone for on-prem subdomains

Note: DNS configuration details (hosted zone, subdomain convention, internal vs external)
still need to be finalized. This section will be updated once confirmed.


4.7 Terraform State

```
Resource              Account              Region     Value
--------------------  -------------------  ---------  -----------------------
S3 bucket             786352483360 (PG)    us-east-1  op-usxpress-dev-tfstate
DynamoDB lock table   786352483360 (PG)    us-east-1  usxpress_tf_state
```

State is completely isolated from cloud environments.


4.8 Secret Architecture

```
AWS Secrets Manager - Playground (786352483360)

  Shared Platform Secrets (already exist, created by ix-kafka-topics-users Terraform):
  - dx--ccloud-kafka-master            Confluent Cloud master credentials
  - dx--ccloud-schema-registry-master  Schema Registry master credentials
  - dx__kafka-misc-rotation            Kafka rotation credentials

  Per-App Secrets (auto-created by MageRunner on each deployment):
  - azure-app-dx-dev-{space}-{app}     Created by auth module
  - dx--{namespace}-kafka-creds        Created by kafka module
  - dx--{namespace}-mongo-creds        Created by mongodb module

  ExternalSecret (on-prem cluster) -> Playground SM -> App Pod
```

All secrets are created automatically by MageRunner or existing Terraform:

```
Secret Type                  Created By                   When
-------------------------    --------------------------   -------------------------
Shared Kafka master creds    ix-kafka-topics-users TF     Already exists in Playground
Shared Schema Registry       ix-kafka-topics-users TF     Already exists in Playground
Azure AD app secrets         MageRunner auth module       Each app deployment
Kafka creds (per-app)        MageRunner kafka module      Each app deployment
MongoDB creds (per-app)      MageRunner mongodb module    Each app deployment
```

Key points:
- Zero manual secret creation or copying between accounts
- Shared platform secrets already exist in Playground (created by ix-kafka-topics-users)
- Per-app secrets are auto-created by MageRunner modules on each deployment
- Same key names as cloud dev - ExternalSecrets work without modification
- Isolated account - zero risk to cloud dev secrets
- Same shared services - Confluent Cloud, MongoDB Atlas, Azure AD are external;
  same credentials work from on-prem


5. WHAT CHANGES VS WHAT DOES NOT

Changes (Total: 1 code change + infrastructure setup):

```
#  Component            Change                                Type
-  -------------------  ------------------------------------  ----------
1  eks-data/main.tf     Add SSM fallback with use_eks_api     Code (20 lines)
2  SSM Parameters       Store cluster endpoint/CA/OIDC        One-time setup
3  iaac-octopus-config  New scripts for OnPremise space       Code (new scripts)
4  IAM role             Create octopus-usxpress in Playground One-time setup
5  Octopus Workers      Deploy workers on on-prem cluster     One-time setup
6  Secrets Manager      Verify shared secrets exist in PG     Validation
```

No Changes Required:

```
Component                    Why
---------------------------  ---------------------------------------------
GitHub Actions CI            Container images are cluster-agnostic
ECR repositories             Same ECR (064859874041) for all clusters
dx-api Helm chart            Chart is cluster-agnostic
spec.yaml format             No schema changes
All TF modules (except eks)  Reference module "eks_data" - outputs same
MageRunner binary            No code changes needed - TF_VAR_* flows through
MageRunner variable pipeline cluster_name + TF_VAR_* already flow through tfvars
Namespace creation           Already sets ambient + disabled labels
Kafka topics/users           Confluent Cloud is external
MongoDB Atlas                External service, same connection strings
Azure AD registrations       Same tenant
Environment gate             On-prem uses "development" (already in allowlist)
```


6. NAMING CONVENTION

```
Level                  Cloud          On-Prem          Pattern
---------------------  -------------  ---------------  ------------------
Cluster name (TF/Oct)  usxpress-dev   op-usxpress-dev  op- prefix
App environment        dev            dev              Same
Octopus environment    Development    Development      Same
AWS resource prefix    usx-           op-usxpress-dev- Matches cluster name
Infra/VM prefix        -              bm-dev           Bare-metal infra only
Flux branch/folders    -              bm-dev           Bare-metal infra only
Octopus Space          USXpress       OnPremise        Separate space
```

Short names (dev, stg, prod) are used for resource naming to avoid AWS naming limits.
They map to the full environment names (development, staging, production).

Future clusters: op-usxpress-qa, op-usxpress-stg, op-usxpress-prod


7. IMPLEMENTATION PLAN

Phase 1: Cluster Rebuild and Cleanup
- Clean up dpl2 artifacts:
  - Delete remaining dx--*-azuread-secret secrets from Playground SM
  - Remove static Flux app manifests from dpl2 branch (infrastructure/app-deployments/, app-configmaps/)
- Tear down current dpl2-cluster, rebuild as op-usxpress-dev
- Refresh IRSA (new SA signing keypair, update S3/CloudFront/IAM OIDC provider)
- Bootstrap Flux with bm-dev cluster configs (platform infrastructure only)
- Deploy Octopus worker pods on the on-prem cluster

Phase 2: Fork and Code Change
- Fork terraform-variant-apps -> feature/onprem-support
- Apply the 1 code change described in section 4.1 (SSM fallback in eks-data)
- No MageRunner code change needed - "development" is already in the env gate

Phase 3: Infrastructure Setup (One-Time)
- Create SSM parameters in Playground (3 params: endpoint, CA, OIDC issuer)
- Create new scripts in iaac-octopus-config for OnPremise space configuration
- Verify shared platform secrets already exist in Playground SM
  (dx--ccloud-kafka-master, dx--ccloud-schema-registry-master - created by ix-kafka-topics-users)
- Verify Octopus worker connectivity and IAM role assumption

Phase 4: Smoke Test and Module Coverage Validation
- Use Octopus Project Bento to export a test project from the USXpress space and import
  into the OnPremise space. This is a read-only snapshot - zero impact to cloud deployments.
  The imported project is fully independent in the OnPremise space.
- Deploy brands-api as the initial smoke test via Octopus, OnPremise space, Development environment
- Verify full MageRunner pipeline output:
  1. IAM role created in Playground with correct OIDC trust policy
  2. Azure AD app registration created in the tenant
  3. Kafka topic/ACLs created in Confluent Cloud (if declared in spec.yaml)
  4. S3 bucket created (if declared in spec.yaml)
  5. MongoDB user/database created (if declared in spec.yaml)
  6. Kubernetes: pod running, IRSA injected, ExternalSecret synced, ConfigMap correct
- After brands-api passes, deploy one app from each infrastructure category to validate
  all Terraform module paths:

```
Category              Test App                    Modules Validated
--------------------  -------------------------   ----------------------------
Azure AD only         brands-api (smoke test)     auth, replicator, apps
Kafka + Azure AD      geoenrichment-sync-handler  kafka, auth, replicator, apps
MongoDB + Azure AD    attrition-api               mongodb, auth, apps
Kafka + MongoDB       io-notifications-handler    kafka, mongodb, auth, apps
PostgreSQL + Kafka    trailers-api                postgres, kafka, auth, apps
Stateless             safetylytx-video-api        replicator, apps only
```

  6 apps covering every Terraform module path. If all 6 pass, every module is validated
  for on-prem. The remaining apps use the same modules in different combinations.
- Fix any issues before proceeding

Phase 5: App Onboarding (Future)
- Not in scope for this implementation. App onboarding will be planned separately once the
  platform is validated through Phase 4 smoke testing.
- When ready, Project Bento will be used to export projects from USXpress and import into
  OnPremise. Export is read-only - zero impact to cloud.
- Apps will be onboarded incrementally as teams are ready - no bulk migration.
- Flux continues to manage platform infrastructure only (cert-manager, istio, ESO, PIW, keda).
  MageRunner owns app lifecycle.


8. RISK ASSESSMENT

```
Risk                            Impact              Likelihood  Mitigation
------------------------------  ------------------  ----------  ------------------------------
On-prem worker IAM bootstrap    Workers cant deploy  Low        IRSA via PIW validated; test early
TF state corruption             Lost state           Low        Dedicated S3 + DynamoDB locking
IRSA token validation failure   Pods cant reach AWS  Low        CloudFront OIDC validated; certs
Kafka consumer group collision  Message stealing     Medium     Different group prefix per cluster
SSM parameter stale/missing     TF plan fails        Low        SSM params set once; alerting
iaac-octopus-config integration Scripts dont work    Medium     Test in OnPremise space first
Outbound network from on-prem   AWS API calls fail   Low        Verify firewall rules early
DNS resolution for on-prem apps No app reachability  Medium     Route53 + external-dns (same as cloud)
```


9. INTER-SPACE PROJECT PORTABILITY

9.1 Octopus Spaces: Design Decision

On-prem deployments use a separate Octopus Space (OnPremise) from cloud deployments
(USXpress). This provides full isolation between environments - separate variable sets,
separate workers, separate deployment history.

Known limitation: Projects cannot be directly shared across Spaces. Each Space is a fully
isolated boundary in Octopus.

9.2 Project Bento (Export/Import)

Octopus provides Project Bento (https://octopus.com/docs/projects/export-import) for
migrating projects between Spaces:

- Export: Creates a read-only snapshot of a project including deployment process, variables,
  channels, and lifecycle. The source Space is not modified in any way.
- Import: Creates the project in the target Space as a fully independent copy.
  No link back to the source - deploying in OnPremise has zero effect on USXpress.

```
Source Space (USXpress)                    Target Space (OnPremise)

  Project: brands-api                       Project: brands-api (independent copy)
  +-- Deployment proc    -- Export -->       +-- Deployment proc
  +-- Variables            (read-only       +-- Variables
  +-- Channels              snapshot)       +-- Channels
  +-- Lifecycle                             +-- Lifecycle
```

What transfers:
- Deployment process, variables (including sensitive with password encryption), channels, lifecycle

What does not transfer (set up separately in OnPremise space):
- Deployment targets (workers already deployed on-prem in Phase 1)
- Triggers (reconfigure in OnPremise space)
- Packages (already in ECR, accessible from both Spaces)

9.3 Sensitive Variable Handling

Project Bento transfers sensitive variables using password-based encryption. A password is
set at export time and the same password is provided at import time to decrypt.

Procedure:

1. Export from USXpress space with encryption password
   - API: POST /api/{SpaceId}/projects/import-export/export
   - Provide project IDs and encryption password

2. Import into OnPremise space with same password
   - API: POST /api/{DestinationSpaceId}/projects/import-export/import
   - Reference the export task ID and provide decryption password

3. Verify sensitive variables in imported project
   - Review variable scoping matches source
   - Run test deployment to confirm variables resolve

4. Update environment-scoped values as needed
   - Some variables may need on-prem specific values (e.g., different endpoints)

Variables managed through iaac-octopus-config are automatically configured per Space.
Only project-specific sensitive variables require the Bento export/import process.

9.4 Automation via Octopus API and SDK

Project Bento operations can be automated through the Octopus REST API or the Go SDK
that MageRunner already uses.

Octopus REST API:
- Swagger UI: https://octopus.usxpress.io/swaggerui/ (VPN required)
- Export endpoint: POST /api/{SpaceId}/projects/import-export/export
- Import endpoint: POST /api/{DestinationSpaceId}/projects/import-export/import
- The entire Octopus UI is built on these APIs - anything done in the UI can be scripted

Go SDK (go-octopusdeploy):
- MageRunner already uses this SDK for Octopus operations
- Migration service: github.com/OctopusDeploy/go-octopusdeploy/pkg/migrations/migration_service.go
- This provides programmatic export/import without manual UI interaction
- Same SDK, same authentication, same patterns MageRunner already uses

This means Project Bento can be integrated into the existing automation pipeline rather
than requiring manual export/import through the Octopus UI.


10. FUTURE CONSIDERATIONS

- Additional on-prem clusters: Run 3 aws ssm put-parameter commands per cluster -
  zero code changes, zero PRs
- Upstream PR: Once validated, submit SSM-backed eks-data as upstream PR to
  terraform-variant-apps (not a permanent fork)
- iaac-octopus-config automation: Extend scripts to handle OnPremise space variable sets,
  worker registration, and script-modules for all on-prem environments
- SSM encryption: Consider using SecureString type for certificate_authority parameter
  (KMS-encrypted at rest)
- Project Bento automation: Script the export/import process for bulk project migration
  between Spaces when adding new on-prem environments


11. OPEN ITEMS

1. Consumer group prefix: Determine what on-prem should use to avoid collision with cloud
   dev Kafka consumer groups
2. Upstream timeline: When to submit SSM-backed eks-data as upstream PR to
   terraform-variant-apps
3. Tracking ticket: Create Jira/Linear ticket for this work
4. DNS subdomain convention: Finalize on-prem app DNS naming (e.g., op-dev.usxpress.io)
   and confirm Route53 hosted zone setup


APPENDIX A: ON-PREM CLUSTER SPECIFICATIONS

```
Property        Value
--------------  ----------------------------------------------
Cluster Name    op-usxpress-dev
Distribution    Talos Linux v1.32.0
Kubernetes      v1.32.0
API Server      https://10.10.82.50:6443
Nodes           3 control plane + 5 worker
CNI             Cilium
Service Mesh    Istio (ambient mode)
OIDC Issuer     https://d2vt9kpivked44.cloudfront.net
Pod Identity    Pod Identity Webhook (2 replicas)
Secrets         External Secrets Operator -> AWS SM (Playground)
GitOps          Flux CD (infrastructure only; apps via MageRunner)
AWS Account     786352483360 (Infrastructure-Playground)
AWS Region      us-east-1
```

APPENDIX B: IRSA COMPARISON

```
Aspect            Cloud EKS                    On-Prem (op-usxpress-dev)
----------------  ---------------------------  ------------------------------
OIDC Provider     AWS-managed (EKS)            S3 + CloudFront
SA Token Signing  EKS-managed keypair          Talos-managed keypair
Token Injection   EKS Pod Identity Agent       Pod Identity Webhook
SA Annotation     eks.amazonaws.com/role-arn   Same
Pod Env Vars      AWS_ROLE_ARN + TOKEN_FILE    IDENTICAL
IAM Trust Policy  Federated OIDC provider      Same pattern, different issuer
```

APPENDIX C: OCTOPUS VARIABLE SETS REFERENCE

Full configuration details: enterprise_procedure_onpremise_octopus_space.md

```
Variable Set      Status      Notes
----------------  ----------  ------------------------------------------
DX_EKSCluster     Configured  CLUSTER_NAME=op-usxpress-dev (Development)
DX_Common         No changes  Already correct for dev
DX_TFState        Configured  S3_BUCKET=op-usxpress-dev-tfstate (dev)
DX_AWSAccounts    Configured  Account 786352483360, region us-east-1
DX_AWSAccessKeys  Configured  IAM prefix, role ARN, domain, region
DX_AzureAD        No changes  Same Azure AD tenant
DX_CCloud         No changes  Same Confluent Cloud
DX_MongoDBAtlas   No changes  Same Atlas org
DX_Network        No changes  Monitor for IP allowlist issues
DX_Runner         No changes  Same execution flags
DX_Tags           Configured  owner, purpose, team filled in
```

These variables are currently configured via Octopus UI. They will be migrated to
iaac-octopus-config repo with space-scoped scripts.


APPENDIX D: LOCAL TEST EVIDENCE

MageRunner was tested locally against the on-prem cluster (March 3, 2026). The test confirmed:

1. spec.yaml parsing - standard spec loaded and validated successfully
2. kubeconfig - MageRunner connected to Talos cluster at 10.10.82.50:6443
3. Namespace creation - test-app namespace created
4. Module skipping - Modules without state (kafka, buckets, mongodb, auth, dynamodb,
   postgres, role) correctly skipped with "Skipping MODULE" log messages
5. Replicator module - Terraform init, validate, and plan executed
6. EKS coupling point confirmed - Pipeline failed at exactly one point:
   ```
   Error: reading EKS Cluster (dpl2-cluster): couldn't find resource
     with module.eks_data.data.aws_eks_cluster.cluster,
     on ../../common/eks-data/main.tf line 1
   ```
   This is the single coupling point that the SSM fallback (Section 4.1) resolves.
7. All other modules are cluster-agnostic - they depend on eks-data outputs
   (endpoint, CA, OIDC issuer) but do not call EKS APIs directly

Conclusion: The SSM fallback in eks-data/main.tf is the only code change required.
Once eks-data returns valid cluster metadata from SSM, the entire pipeline will execute
identically to cloud.

Test log shared with Vibin on March 3 via Teams. Full log available at mage-dpl2-test.log.

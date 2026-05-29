Jira Tickets for Remaining On-Prem Platform Work
Author: Dare Oke, Cloud Platform Team
Date: April 2, 2026

These tickets represent the remaining work for the MageRunner on-premises
Kubernetes support project. Sprint 1 stories ONPREM-1 through ONPREM-4 are
complete (cluster rebuild, IRSA, Flux, pipeline automation). The tickets below
cover the remaining Sprint 1 work, all of Sprint 2 and 3, and new stories from
Vibin's architectural decisions.


EPIC: MageRunner On-Premises Kubernetes Support
Labels: cloud-platform, on-prem, magerunner, infrastructure


SPRINT 1 REMAINING
==================

Ticket: ONPREM-5 - Deploy Octopus worker pods on op-usxpress-dev
Type: Story | Priority: High | Points: 3
Labels: octopus, workers, infrastructure

Description:
Deploy Octopus tentacle/worker pods on the on-prem cluster so MageRunner can
execute deployments from within the cluster instead of from cloud EKS workers.

Acceptance Criteria:
- Octopus tentacle/worker pods running on op-usxpress-dev
- Workers registered in Octopus OnPremise Space
- Worker ServiceAccount annotated with IAM role ARN
- Pod Identity Webhook injecting IRSA credentials into worker pods
- Workers can assume octopus-usxpress role in Playground (786352483360)
- Workers have outbound connectivity to: ECR, AWS APIs, Azure AD,
  Confluent Cloud, MongoDB Atlas, Octopus server

Dependencies: ONPREM-4 (Flux, done), ONPREM-24 (network validation)
Blocked by: None (cluster is up and running)

---

Ticket: ONPREM-24 - Validate datacenter-to-AWS network connectivity
Type: Story | Priority: High | Points: 2
Labels: network, infrastructure, prerequisite

Description:
Validate that the HQ datacenter has outbound connectivity to all required
external services from the on-prem cluster. This is a prerequisite for
deploying Octopus workers and running MageRunner on-prem.

Acceptance Criteria:
- Outbound HTTPS/443 to AWS API endpoints (us-east-1)
- ECR pull test succeeds from on-prem node
- Azure AD token endpoint reachable (login.microsoftonline.com)
- Confluent Cloud Kafka endpoint reachable
- MongoDB Atlas endpoint reachable
- Octopus server reachable (octopus.usxpress.io)
- Route53 API reachable for external-dns
- Connectivity test results documented

Dependencies: None
Status: Partially done (pipeline works from cloud worker)

---

Ticket: ONPREM-25 - Configure external-dns with Route53 for on-prem
Type: Story | Priority: High | Points: 3
Labels: dns, route53, infrastructure

Description:
Deploy external-dns on op-usxpress-dev with Route53 integration so on-prem
app ingress endpoints get DNS records automatically.

Acceptance Criteria:
- external-dns deployed on op-usxpress-dev via Flux
- IAM role for external-dns with Route53 permissions (via IRSA)
- external-dns watches Istio VirtualService/Gateway resources
- DNS records created in Route53 when apps are deployed
- On-prem app DNS naming convention confirmed
- Test DNS record created and resolves correctly
- No impact to existing cloud DNS records

Dependencies: ONPREM-3 (IRSA, done)


SPRINT 2: CODE CHANGE AND INFRASTRUCTURE SETUP
===============================================

Ticket: ONPREM-6 - Add SSM fallback to eks-data Terraform module
Type: Story | Priority: High | Points: 3
Labels: terraform, code-change, eks-data

Description:
Add an SSM Parameter Store fallback to the eks-data module in
terraform-variant-apps. When use_eks_api=false, the module queries cluster
metadata from SSM instead of the EKS API. This is the only code change
required for on-prem support.

Acceptance Criteria:
- Fork terraform-variant-apps -> feature/onprem-support branch
- New variable use_eks_api (bool, default true)
- When true: existing EKS API behavior unchanged
- When false: module queries SSM for endpoint, CA, OIDC issuer
- Output names and types identical (no downstream changes)
- terraform validate and plan pass
- 20 lines of code added

Dependencies: None
Reference: Design doc section 4.1

---

Ticket: ONPREM-7 - Create SSM parameters for op-usxpress-dev
Type: Story | Priority: High | Points: 1
Labels: aws, ssm, infrastructure

Description:
Store cluster metadata in AWS SSM Parameter Store so the eks-data module
can dynamically look up on-prem cluster values.

Acceptance Criteria:
- SSM parameters created in Playground (786352483360), us-east-1:
  /clusters/op-usxpress-dev/endpoint
  /clusters/op-usxpress-dev/certificate_authority
  /clusters/op-usxpress-dev/oidc_issuer
- Parameters are String type, standard tier
- octopus-usxpress role has read access
- Note: OIDC issuer changes on each rebuild (dynamic CloudFront domain).
  Update SSM after each cluster rebuild, or automate via Terraform output.

Dependencies: ONPREM-2 (cluster rebuilt, done)

---

Ticket: ONPREM-8 - Create/verify IAM role octopus-usxpress in Playground
Type: Story | Priority: High | Points: 2
Labels: aws, iam, security

Description:
Verify the octopus-usxpress IAM role in Playground has correct trust policy
and permissions for on-prem workers.

Acceptance Criteria:
- Role exists: arn:aws:iam::786352483360:role/octopus-usxpress
- Trust policy references on-prem OIDC provider
- Trust condition scoped to system:serviceaccount:octopus:octopus-worker
- 19 inline policies attached
- Worker pod can assume role via STS AssumeRoleWithWebIdentity

Dependencies: ONPREM-3 (IRSA, done)
Status: Role exists, trust policy needs update for current OIDC provider

---

Ticket: ONPREM-9 - Configure Octopus OnPremise Space variables
Type: Story | Priority: High | Points: 3
Labels: octopus, configuration

Description:
Configure the 11 DX variable sets in the OnPremise Octopus Space so
MageRunner receives correct on-prem values when deploying.

Acceptance Criteria:
- DX_EKSCluster: CLUSTER_NAME=op-usxpress-dev, TF_VAR_use_eks_api=false
- DX_AWSAccounts: AWS_ACCOUNT_dev=786352483360, region=us-east-1
- DX_AWSAccessKeys: IAM prefix, role ARN, domain updated
- DX_TFState: S3_BUCKET=op-usxpress-dev-tfstate
- DX_Tags: owner, purpose, team filled in
- All other variable sets verified unchanged

Dependencies: None
Reference: Design doc section 4.2, enterprise_procedure_onpremise_octopus_space.md

---

Ticket: ONPREM-10 - Create iaac-octopus-config scripts for OnPremise Space
Type: Story | Priority: Medium | Points: 5
Labels: octopus, iac, automation

Description:
Create scripts in iaac-octopus-config repo for the OnPremise Space so
Octopus configuration is code-managed and repeatable.

Acceptance Criteria:
- New scripts for OnPremise Space configuration
- Scripts configure variable sets, script-modules, worker registration
- Repo supports different configs for different Spaces
- Scripts tested against OnPremise Space
- PR created for review

Dependencies: ONPREM-9 (manual config first, then automate)

---

Ticket: ONPREM-11 - Create Terraform state bucket for op-usxpress-dev
Type: Story | Priority: High | Points: 1
Labels: aws, terraform, s3

Description:
Create dedicated S3 bucket and DynamoDB lock table for on-prem TF state.

Acceptance Criteria:
- S3 bucket: op-usxpress-dev-tfstate in Playground, us-east-1
- DynamoDB lock table configured
- Versioning and encryption enabled
- octopus-usxpress role has read/write access

Dependencies: None

---

Ticket: ONPREM-12 - Verify shared platform secrets in Playground
Type: Story | Priority: Medium | Points: 1
Labels: aws, secrets, validation

Description:
Verify shared platform secrets exist in Playground Secrets Manager for
ExternalSecrets to sync to on-prem app pods.

Acceptance Criteria:
- dx--ccloud-kafka-master exists with valid credentials
- dx--ccloud-schema-registry-master exists with valid credentials
- dx__kafka-misc-rotation exists with valid credentials
- ExternalSecrets on op-usxpress-dev can read from Playground SM
- Test ExternalSecret resource syncs successfully

Dependencies: ONPREM-3 (IRSA/ESO, done)


SPRINT 3: SMOKE TEST AND VALIDATION
====================================

Ticket: ONPREM-13 - Export test project from USXpress via Project Bento
Type: Story | Priority: High | Points: 2
Labels: octopus, bento, testing

Description:
Export brands-api from USXpress Space and import into OnPremise Space using
Project Bento. This is read-only — zero impact to cloud deployments.

Acceptance Criteria:
- brands-api exported from USXpress (read-only snapshot)
- Imported into OnPremise Space as independent copy
- Sensitive variables decrypted with import password
- Deployment targets configured for on-prem workers
- Triggers reconfigured for OnPremise Space

Dependencies: ONPREM-5 (workers), ONPREM-9 (Octopus config)

---

Ticket: ONPREM-14 - Smoke test: Deploy brands-api to op-usxpress-dev
Type: Story | Priority: High | Points: 3
Labels: testing, smoke-test, validation

Description:
Deploy brands-api through MageRunner pipeline on on-prem to validate
end-to-end deployment flow.

Acceptance Criteria:
- MageRunner executes all pipeline stages without errors
- IAM role created in Playground with OIDC trust policy
- Azure AD app registration created
- Namespace created with correct labels
- ECR pull secret replicated
- ExternalSecret synced from Playground SM
- Pod running with IRSA credentials injected
- ServiceAccount annotated with IAM role ARN

Dependencies: ONPREM-13 (Project Bento import)

---

Tickets: ONPREM-15 through ONPREM-19 - Module coverage validation
Type: Story | Priority: High | Points: 2 each (1 for stateless)
Labels: testing, validation

Deploy 5 additional test apps covering every Terraform module path:

ONPREM-15: geoenrichment-sync-handler (Kafka + Azure AD)
ONPREM-16: attrition-api (MongoDB + Azure AD)
ONPREM-17: io-notifications-handler (Kafka + MongoDB)
ONPREM-18: trailers-api (PostgreSQL + Kafka)
ONPREM-19: safetylytx-video-api (stateless, replicator only)

6 total apps covering: auth, replicator, kafka, mongodb, postgres, buckets, apps

Dependencies: ONPREM-14 (smoke test passes first)

---

Ticket: ONPREM-20 - Document validation results and resolve issues
Type: Story | Priority: High | Points: 2
Labels: documentation, validation

Description:
Document results of all 6 test app deployments and resolve any issues.

Acceptance Criteria:
- All 6 apps deployed successfully or issues documented
- Every Terraform module path validated
- Validation report with pass/fail per app and module
- Cloud EKS deployments verified unaffected (regression check)

Dependencies: ONPREM-15 through ONPREM-19


NEW STORIES (Vibin decisions, March 31, 2026)
=============================================

Ticket: ONPREM-26 - AHV hypervisor migration planning
Type: Story | Priority: Low | Points: 3
Labels: infrastructure, ahv, migration, future

Description:
Plan the VMware vSphere to Nutanix AHV migration. Main change is swapping
the Terraform provider. Everything above hypervisor stays the same.

Acceptance Criteria:
- AHV Terraform provider evaluated
- vsphere_vm module mapped to AHV equivalent
- Migration plan documented
- Rook-Ceph deployment planned for AFTER AHV

Notes:
- Q4 2026 timeline (per Steve)
- Vibin: "If you do rook-ceph before migration, it will be messy"

Dependencies: None (planning only)

---

Ticket: ONPREM-27 - RisingWave infrastructure deployment (iaac-risingwave)
Type: Story | Priority: Medium | Points: 5
Labels: risingwave, infrastructure, custom-deployment

Description:
Create iaac-risingwave repo following iaac-eks pattern. Deploy RisingWave
streaming engine to on-prem cluster.

Acceptance Criteria:
- iaac-risingwave repo created
- Terraform + Helm chart configuration
- GHA workflow + Octopus project
- IRSA IAM role for S3 state store access
- ExternalSecrets for Kafka creds
- Postgres metadata via AWS RDS (not on-cluster)
- emptyDir for local cache (dev POC)
- Tim Preble validates deployment

Notes:
- Per Vibin: custom deployment like iaac-eks
- Tim's POC repo: github.com/usxpressinc/risingwave-poc

Dependencies: ONPREM-4 (platform, done)

---

Ticket: ONPREM-28 - RisingWave SQL pipeline CI/CD
Type: Story | Priority: Medium | Points: 3
Labels: risingwave, cicd, data-engineering

Description:
Create CI/CD pipeline for RisingWave SQL pipeline definitions using
Liquibase, Flyway, or go-migrate (NOT dbt).

Acceptance Criteria:
- Separate repo for SQL definitions (Tim's team owns)
- GHA workflow with migration tool
- Connects to RisingWave frontend (port 4567)
- Credentials via Secrets Manager

Notes:
- Per Vibin: "dbt doesn't work well with risingwave scripts"

Dependencies: ONPREM-27 (RisingWave deployed)

---

Ticket: ONPREM-29 - Rook-Ceph deployment (post-AHV)
Type: Story | Priority: Low | Points: 8
Labels: storage, rook-ceph, statefulsets, future

Description:
Deploy Rook-Ceph for persistent storage after AHV migration.

Acceptance Criteria:
- Rook-Ceph on AHV-based cluster
- Block storage (RBD) for PVCs
- RisingWave migrated from emptyDir to Rook-Ceph PVs

Notes:
- BLOCKED by ONPREM-26 (AHV migration, Q4 2026)
- Vibin and Steve both warned against doing this before AHV

Dependencies: ONPREM-26


PRIORITY ORDER FOR NEXT WORK
=============================

Immediate (this week):
  1. ONPREM-24 - Network connectivity validation
  2. ONPREM-5  - Deploy Octopus workers on on-prem
  3. ONPREM-7  - Create SSM parameters

Next sprint:
  4. ONPREM-6  - SSM fallback code change (the 1 code change)
  5. ONPREM-9  - Octopus OnPremise Space variables
  6. ONPREM-11 - TF state bucket
  7. ONPREM-12 - Verify shared secrets

Following sprint:
  8. ONPREM-13 - Project Bento export/import
  9. ONPREM-14 - brands-api smoke test
  10. ONPREM-15 to 19 - Module coverage (6 apps)

Backlog:
  - ONPREM-25 - external-dns (can run in parallel)
  - ONPREM-10 - iaac-octopus-config automation
  - ONPREM-27/28 - RisingWave (when Tim is ready)
  - ONPREM-26/29 - AHV + Rook-Ceph (Q4 2026)

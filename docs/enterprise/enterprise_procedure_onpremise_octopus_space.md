# Enterprise Procedure: OnPremise Octopus Space Configuration

**Author:** Doke (Cloud Platform Team)
**Date:** March 12, 2026
**Status:** In Progress
**Scope:** Configure Octopus Deploy OnPremise Space for MageRunner CI/CD to on-prem Talos clusters

---

## 1. Overview

This document captures all configuration changes made to the **OnPremise** Octopus Space to enable the DX MageRunner pipeline to deploy applications to on-prem bare-metal Talos Kubernetes clusters.

The OnPremise space mirrors the cloud USXpress space but targets on-prem infrastructure. This is a **repeatable procedure** — follow the same pattern for each new on-prem environment (dev → QA → staging → prod).

### Architecture

```
Cloud (existing):
  Octopus Space: USXpress → MageRunner → EKS clusters (usxpress-dev, qa-one, usxpress-prod)

On-Prem (new):
  Octopus Space: OnPremise → MageRunner → Talos clusters (op-usxpress-dev, op-usxpress-qa, op-usxpress-prod)
```

### Decision Log

| Decision | Made By | Date | Rationale |
|----------|---------|------|-----------|
| Separate Octopus Space for on-prem | Vibin Daniel (DX Lead) | March 11 2026 | Clean separation from cloud pipelines |
| Environment name: `dev` (not dpl2) | Vibin Daniel | March 11 2026 | Apps should see standard env names |
| Cluster name: `op-usxpress-dev` | Doke + Claude | March 12 2026 | Mirrors cloud naming (`usxpress-dev`) with `op-` prefix |
| Infrastructure prefix: `bm-dev` | Doke + Claude | March 11 2026 | Used for VM names, Flux branches, Talos configs |

---

## 2. Prerequisites

Before configuring variable sets:

- [ ] OnPremise Space created in Octopus (Spaces → Add Space → "OnPremise")
- [ ] Environment created: `development` (Infrastructure → Environments → Add)
- [ ] Lifecycle created: `onprem-dev` (Library → Lifecycles → Add → Phase: development, Manual)
- [ ] DX variable sets cloned from USXpress space (Terraform creates these — they should already exist)
- [ ] AWS resources ready:
  - S3 bucket for Terraform state (`dpl2-local-test-tfstate` in Playground)
  - DynamoDB table for state locking (`usxpress_tf_state` in Playground, us-east-1)
  - IAM role `octopus-usxpress` in target AWS account

---

## 3. Variable Set Changes

### Naming Convention

On-prem environments use `op-` prefix on cluster names to avoid collision with cloud EKS clusters:

| Environment | Cloud Cluster | On-Prem Cluster | AWS Account | Region |
|-------------|--------------|-----------------|-------------|--------|
| dev | usxpress-dev | op-usxpress-dev | 786352483360 (Playground) | us-east-1 |
| qa | qa-one | op-usxpress-qa | TBD | TBD |
| staging | usxpress-staging | op-usxpress-staging | TBD | TBD |
| prod | usxpress-prod | op-usxpress-prod | TBD | TBD |

### 3.1 DX_EKSCluster

**What it controls:** Cluster name and region for MageRunner's Terraform modules (eks-data lookup).

| Variable | Value | Scope | Cloud Default | Changed? |
|----------|-------|-------|---------------|----------|
| `CLUSTER_NAME` | `op-usxpress-dev` | development | `usxpress-dev` | **YES** |
| `CLUSTER_REGION` | `us-east-1` | development | `us-east-2` | **YES** |

**Why:** The mock eks-data module uses `CLUSTER_NAME` to detect non-EKS clusters and return static values (endpoint, OIDC, CA) instead of calling the AWS EKS API. Must NOT match any real EKS cluster name.

**For QA/Prod:** Set `CLUSTER_NAME` = `op-usxpress-qa` / `op-usxpress-prod`, scope to respective environment.

---

### 3.2 DX_Common

**What it controls:** Environment abbreviations used across all Terraform modules and Helm charts.

| Variable | Value | Scope | Cloud Default | Changed? |
|----------|-------|-------|---------------|----------|
| `env_short` | `dev` | development | `dev` | No |
| `environment_abbreviation` | `dev` | development | `dev` | No |

**Why:** Already correct — on-prem dev uses the same app-level environment name as cloud dev.

**For QA/Prod:** Set `env_short` = `qa` / `prod`, `environment_abbreviation` = `qa` / `prod`.

---

### 3.3 DX_TFState

**What it controls:** S3 bucket and DynamoDB table for Terraform state storage.

| Variable | Value | Scope | Cloud Default | Changed? |
|----------|-------|-------|---------------|----------|
| `S3_BUCKET` | `dpl2-local-test-tfstate` | development | `usxpress-dev-tfstate` | **YES** |

**Why:** On-prem Terraform state goes to the Playground AWS account (786352483360), not the cloud dev account.

**AWS Resources Created:**
- S3 bucket: `dpl2-local-test-tfstate` (already existed from local testing)
- DynamoDB table: `usxpress_tf_state` in Playground us-east-1
  - Partition key: `LockID` (String)
  - Billing: PAY_PER_REQUEST
  - Created with:
    ```bash
    aws --profile playground dynamodb create-table \
      --table-name usxpress_tf_state \
      --attribute-definitions AttributeName=LockID,AttributeType=S \
      --key-schema AttributeName=LockID,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST \
      --region us-east-1
    ```

**For QA/Prod:** Create dedicated S3 buckets (e.g., `op-usxpress-qa-tfstate`) in the target AWS account. Create DynamoDB lock table if not already present.

---

### 3.4 DX_AWSAccounts

**What it controls:** AWS account IDs and regions, looked up by MageRunner using `environment_abbreviation` as key suffix (e.g., `AWS_ACCOUNT_dev`).

| Variable | Value | Scope | Cloud Default | Changed? |
|----------|-------|-------|---------------|----------|
| `AWS_ACCOUNT_dev` | `786352483360` | unscoped | `700736442855` | **YES** |
| `AWS_REGION_dev` | `us-east-1` | unscoped | `us-east-2` | **YES** |

**Why:** MageRunner constructs `AWS_ACCOUNT_{env_abbreviation}` at runtime. Since `environment_abbreviation=dev`, it resolves `AWS_ACCOUNT_dev`. On-prem dev uses Playground (786352483360) in us-east-1 instead of cloud dev (700736442855) in us-east-2.

**Note:** `AWS_ACCOUNT_dpl` (786352483360) already existed but isn't used — MageRunner keys off `dev`, not `dpl`.

**For QA/Prod:** Override `AWS_ACCOUNT_qa` / `AWS_ACCOUNT_prod` with the on-prem target AWS accounts.

---

### 3.5 DX_AWSAccessKeys

**What it controls:** IAM roles, resource prefixes, and domain used by MageRunner during deployment.

| Variable | Value | Scope | Cloud Default | Changed? |
|----------|-------|-------|---------------|----------|
| `AWS_DEFAULT_REGION` | `us-east-1` | development | `us-east-2` | **YES** |
| `AWS_IAM_PREFIX` | `op-usxpress-dev` | unscoped | (varies) | **YES** |
| `aws_resource_name_prefix` | `op-usxpress-dev-` | unscoped | (varies) | **YES** |
| `AWS_ROLE_TO_ASSUME` | `arn:aws:iam::786352483360:role/octopus-usxpress` | development | `arn:aws:iam::700736442855:role/octopus-usxpress` | **YES** |
| `DOMAIN` | `dev.usxpress.io` | development | `usxpress-dev.com` | **YES** |
| `ECR_ROLE_TO_ASSUME` | `arn:aws:iam::064859874041:role/eks-github-runner` | unscoped | same | No |

**Why:**
- `AWS_DEFAULT_REGION`: Playground is us-east-1
- `AWS_IAM_PREFIX` / `aws_resource_name_prefix`: Follows cluster naming convention (op-usxpress-dev)
- `AWS_ROLE_TO_ASSUME`: Octopus worker assumes into Playground for SM/S3/IRSA operations
- `DOMAIN`: On-prem apps use `dev.usxpress.io` (not `usxpress-dev.com`)
- `ECR_ROLE_TO_ASSUME`: Unchanged — container images always come from infra-common (064859874041)

**IMPORTANT:** The IAM role `octopus-usxpress` must exist in the target AWS account (786352483360). Verify:
```bash
aws --profile playground iam get-role --role-name octopus-usxpress
```

**For QA/Prod:** Update `AWS_ROLE_TO_ASSUME` ARN with target account, set `DOMAIN` to `qa.usxpress.io` / `usxpress.io`, update prefixes to `op-usxpress-qa-` / `op-usxpress-prod-`.

---

### 3.6 DX_AzureAD

**What it controls:** Azure AD service principal for app registration (MageRunner auth module).

| Variable | Value | Scope | Changed? |
|----------|-------|-------|----------|
| `ARM_az_prefix` | `dev` | development | No |
| `ARM_CLIENT_ID` | (existing) | unscoped | No |
| `ARM_CLIENT_SECRET` | (existing) | unscoped | No |
| `ARM_CREATE_LOCALHOST_PORTS` | `true` | development | No |
| `ARM_TENANT_ID` | (existing) | unscoped | No |

**Why:** Same Azure AD tenant for all environments (cloud and on-prem). No changes needed.

**For QA/Prod:** Add environment-scoped `ARM_az_prefix` = `qa` / `prod`. Verify same service principal has permissions or create new ones.

---

### 3.7 DX_CCloud (Confluent Cloud / Kafka)

**What it controls:** Kafka cluster credentials, schema registry, REST endpoints.

**No changes needed.** On-prem apps connect to the same Confluent Cloud Kafka as cloud dev. Consumer group isolation is handled at the Helm chart level (different consumer group names prevent message stealing).

**For QA/Prod:** The variable set already has production-scoped values for prod Kafka cluster. Add QA-scoped values if a separate Kafka cluster exists for QA.

---

### 3.8 DX_MongoDBAtlas

**What it controls:** MongoDB Atlas API keys for Terraform provisioning.

**No changes needed.** Same shared MongoDB Atlas organization. All values unscoped.

**For QA/Prod:** No changes expected — same Atlas org.

---

### 3.9 DX_Network

**What it controls:** IP allowlists for private/public access control (used by Terraform modules for service allowlisting).

| Variable | Value | Scope | Changed? |
|----------|-------|-------|----------|
| `PRIVATE_ACCESS_CONTROL_LIST` | `["172.17.0.0/16", "192.168.0.0/16"]` | unscoped | No (monitor) |
| `PUBLIC_ACCESS_CONTROL_LIST` | `["66.18.38.64/26", "208.93.34.128/26"]` | unscoped | No |

**Note:** bm-dev nodes are on `10.10.82.0/24` which is NOT in the private access list. Not referenced by MageRunner directly — used by Terraform modules for external service IP allowlisting. **If MongoDB Atlas or Confluent Cloud connections fail from on-prem nodes, add `10.10.82.0/24` (or broader CIDR) to `PRIVATE_ACCESS_CONTROL_LIST`.**

**For QA/Prod:** Add on-prem network CIDRs if needed for the respective site's subnet.

---

### 3.10 DX_Runner

**What it controls:** MageRunner execution flags (schema validation, Terraform destroy, logging).

| Variable | Value | Scope | Changed? |
|----------|-------|-------|----------|
| `SCHEMA_PLACE_HOLDER_CHECK` | `true` | unscoped | No |
| `SCHEMA_VALIDATE_DRY_RUN` | `false` | development | No |
| `TERRAFORM_DESTROY` | `false` | unscoped | No |
| `TF_LOG` | (empty) | development | No |

**No changes needed.**

**For QA/Prod:** Same pattern — `SCHEMA_VALIDATE_DRY_RUN=false`, `TERRAFORM_DESTROY=false`.

---

### 3.11 DX_Tags

**What it controls:** AWS resource tags applied to all resources created by MageRunner's Terraform.

| Variable | Value | Scope | Changed? |
|----------|-------|-------|----------|
| `owner` | `cloud-platform` | unscoped | **YES** (was empty) |
| `purpose` | `on-prem-dev` | unscoped | **YES** (was empty) |
| `team` | `cloudops` | unscoped | **YES** (was empty) |

**For QA/Prod:** Update `purpose` to `on-prem-qa` / `on-prem-prod`.

---

## 4. Infrastructure Setup (Post-Cluster Rebuild)

### 4.1 Kubeconfig Distribution

Octopus workers on EKS need a kubeconfig to reach the on-prem cluster. Script: `scripts/setup-bm-dev-octopus.sh`

```bash
# 1. Generate standalone kubeconfig
kubectl config view --context="admin@op-usxpress-dev" --minify --flatten > /tmp/bm-dev-kubeconfig.yaml

# 2. Copy to all Octopus worker pods on EKS
for i in 0 1 2; do
  kubectl --context=usxpress-dev cp /tmp/bm-dev-kubeconfig.yaml octopus/octopusworker-$i:/tmp/bm-dev-kubeconfig.yaml
  kubectl --context=usxpress-dev exec -n octopus octopusworker-$i -- mkdir -p /etc/kubernetes
  kubectl --context=usxpress-dev exec -n octopus octopusworker-$i -- cp /tmp/bm-dev-kubeconfig.yaml /etc/kubernetes/bm-dev-config
done

# 3. Verify connectivity
kubectl --context=usxpress-dev exec -n octopus octopusworker-0 -- \
  kubectl --kubeconfig=/etc/kubernetes/bm-dev-config get nodes
```

**Note:** Kubeconfig path `/etc/kubernetes/bm-dev-config` must match the `KUBECONFIG` variable set in the project or variable set.

### 4.2 Worker Pool

The OnPremise space uses the same Octopus worker pool as cloud (`usxpress-development`). Workers are pods running on the EKS cluster that can reach the on-prem cluster via VPN/direct network.

### 4.3 Network Verification

EKS workers must be able to reach the on-prem Talos API:
```bash
kubectl --context=usxpress-dev exec -n octopus octopusworker-0 -- \
  curl -sk https://10.10.82.30:6443/healthz
# Expected: "ok"
```

---

## 5. IAM Role Verification

The `octopus-usxpress` role in Playground (786352483360) must allow:
- `secretsmanager:GetSecretValue` — read app secrets
- `s3:GetObject`, `s3:PutObject` — Terraform state
- `dynamodb:PutItem`, `dynamodb:GetItem`, `dynamodb:DeleteItem` — state locking
- `iam:CreateRole`, `iam:AttachRolePolicy` — IRSA role creation
- `sts:AssumeRole` — cross-account if needed

Verify the role exists:
```bash
aws --profile playground iam get-role --role-name octopus-usxpress
```

---

## 6. Octopus Project Setup (Per App)

For each application to deploy:

1. **Create Project** in OnPremise space
   - Name: `{app-name}` (e.g., `brands-api`)
   - Project Group: match cloud grouping (e.g., `enterprise`)
   - Lifecycle: `onprem-dev`

2. **Link Variable Sets**
   - DX_EKSCluster, DX_Common, DX_TFState, DX_AWSAccounts
   - DX_AWSAccessKeys, DX_AzureAD, DX_CCloud, DX_MongoDBAtlas
   - DX_Network, DX_Runner, DX_Tags

3. **Set Deployment Process**
   - Step: MageRunner (dx-apply)
   - Worker Pool: `usxpress-development`

4. **Create Release → Deploy to development**

---

## 7. Verification Checklist

After deploying an app via Octopus:

```bash
# Pod running
kubectl --context=admin@op-usxpress-dev get pods -n {namespace} | grep {app}

# ConfigMap created by Helm
kubectl --context=admin@op-usxpress-dev get configmap {app}-chart -n {namespace} -o yaml

# ExternalSecret syncing
kubectl --context=admin@op-usxpress-dev get externalsecrets -n {namespace} | grep {app}

# IRSA working
kubectl --context=admin@op-usxpress-dev exec -n {namespace} deploy/{app} -- env | grep AWS_ROLE_ARN
```

---

## 8. Replicating for QA / Staging / Production

When standing up the next on-prem environment, repeat this procedure:

### Quick Reference: What Changes Per Environment

| Variable Set | What to Change | Key Variables |
|-------------|----------------|---------------|
| DX_EKSCluster | Cluster name + region | `CLUSTER_NAME`, `CLUSTER_REGION` |
| DX_Common | Env abbreviation | `env_short`, `environment_abbreviation` |
| DX_TFState | S3 bucket | `S3_BUCKET` |
| DX_AWSAccounts | Account ID + region | `AWS_ACCOUNT_{env}`, `AWS_REGION_{env}` |
| DX_AWSAccessKeys | Role ARN, prefix, domain, region | `AWS_ROLE_TO_ASSUME`, `AWS_IAM_PREFIX`, `aws_resource_name_prefix`, `DOMAIN`, `AWS_DEFAULT_REGION` |
| DX_AzureAD | AZ prefix | `ARM_az_prefix` |
| DX_Tags | Purpose tag | `purpose` |

### What Stays the Same

- DX_CCloud (same Kafka, unless dedicated cluster for env)
- DX_MongoDBAtlas (same Atlas org)
- DX_Network (unless different subnet)
- DX_Runner (execution flags)
- ECR_ROLE_TO_ASSUME (always 064859874041)
- Azure AD tenant + service principal

### Steps

1. Add new Environment in OnPremise space (e.g., `qa`)
2. Update Lifecycle to include new phase
3. Add environment-scoped variable overrides (see table above)
4. Create mock eks-data entry for new cluster name (e.g., `op-usxpress-qa`)
5. Distribute kubeconfig for new cluster to Octopus workers
6. Create/update Octopus projects with new environment in lifecycle
7. Test single app deployment, then roll out

---

## 9. Related Documents

| Document | Purpose |
|----------|---------|
| `design_doc_magerunner_bare_metal.md` | Design doc for Vibin review (mock eks-data approach) |
| `dpl2_teardown_bm_dev_rebuild_plan.md` | 7-phase cluster rebuild plan |
| `scripts/setup-bm-dev-octopus.sh` | Worker kubeconfig setup script |
| `scripts/copy-dev-secrets-to-playground.sh` | Copy secrets from dev SM to Playground SM |
| `dev_cluster_secret_architecture.md` | Secret naming patterns and architecture |
| `enterprise_procedure_irsa_implementation.md` | IRSA setup for on-prem (Pod Identity Webhook) |

---

## 10. Appendix: Complete Variable Diff (Cloud vs On-Prem Dev)

| Variable | Cloud Dev Value | OnPremise Dev Value |
|----------|----------------|---------------------|
| `CLUSTER_NAME` | `usxpress-dev` | `op-usxpress-dev` |
| `CLUSTER_REGION` | `us-east-2` | `us-east-1` |
| `AWS_ACCOUNT_dev` | `700736442855` | `786352483360` |
| `AWS_REGION_dev` | `us-east-2` | `us-east-1` |
| `AWS_DEFAULT_REGION` | `us-east-2` | `us-east-1` |
| `AWS_IAM_PREFIX` | (cloud value) | `op-usxpress-dev` |
| `aws_resource_name_prefix` | (cloud value) | `op-usxpress-dev-` |
| `AWS_ROLE_TO_ASSUME` | `arn:aws:iam::700736442855:role/octopus-usxpress` | `arn:aws:iam::786352483360:role/octopus-usxpress` |
| `DOMAIN` | `usxpress-dev.com` | `dev.usxpress.io` |
| `S3_BUCKET` | `usxpress-dev-tfstate` | `dpl2-local-test-tfstate` |
| `owner` | (cloud value) | `cloud-platform` |
| `purpose` | (cloud value) | `on-prem-dev` |
| `team` | (cloud value) | `cloudops` |

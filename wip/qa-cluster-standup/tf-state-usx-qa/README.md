# QA cluster TF state backend

**Ticket:** [INFRA-1562](https://usxpress.atlassian.net/browse/INFRA-1562) (part of INFRA-1585 execution)

## What this provisions

- S3 bucket `lazy-tf-state-usx-qa` in USX-QA us-east-2 (SSE-KMS, versioned, PABs on)
- DynamoDB lock table `lazy-tf-state-usx-qa-lock`
- CRR replica bucket `lazy-tf-state-usx-qa-replica` in USX-QA us-west-2 (same-account, different region)
- Source + destination CMKs (rotating enabled)
- IAM role for the S3-service to perform the replication

All three SSE-KMS CRR gotchas are baked in (see comments in `main.tf`).

## Prerequisites

- AWS SSO login for USX-QA (`527101283767`) — role: `AWSAdministratorAccess`
- `AWS_PROFILE=usx-qa` (or whatever your profile name is) with permissions in both us-east-2 and us-west-2

## Apply (bootstrap — local state first, then migrate to remote)

```bash
cd wip/qa-cluster-standup/tf-state-usx-qa

# Fresh init (local state)
export AWS_PROFILE=usx-qa
terraform init

# Plan + apply — provisions the bucket + lock table + CRR
terraform plan -out plan.tfplan
terraform apply plan.tfplan

# Capture the backend config for iaac-talos
terraform output -raw backend_config_snippet
```

## After apply — migrate this module's own state into itself

Once the bucket and lock table exist, we migrate THIS module's state file into the bucket it just created (self-hosting pattern):

```bash
cat > backend.tf <<'EOF'
terraform {
  backend "s3" {
    bucket         = "lazy-tf-state-usx-qa"
    key            = "iaac/qa-tf-state-backend/self.tfstate"
    region         = "us-east-2"
    dynamodb_table = "lazy-tf-state-usx-qa-lock"
    encrypt        = true
  }
}
EOF

terraform init -migrate-state
```

Answer "yes" when it asks to copy the local state to S3.

## Wire iaac-talos to use this backend

On the iaac-talos `feature/op-usxpress-qa` branch:

```bash
cd ~/work/iaac-talos/deploy/terraform

terraform init \
  -backend-config="bucket=lazy-tf-state-usx-qa" \
  -backend-config="key=iaac/talos/op-usxpress-qa.tfstate" \
  -backend-config="region=us-east-2" \
  -backend-config="dynamodb_table=lazy-tf-state-usx-qa-lock" \
  -backend-config="encrypt=true"
```

## Verify CRR after first state file lands

CRR is async — takes 15-60 min for first replication. Verify via:

```bash
# Get replication status on a specific object
aws s3api head-object \
  --bucket lazy-tf-state-usx-qa \
  --key iaac/talos/op-usxpress-qa.tfstate \
  --profile usx-qa \
  --query 'ReplicationStatus'
# Expected: "COMPLETED"
```

If it returns nothing at all (not "COMPLETED" or "PENDING"), one of the three SSE-KMS gotchas fired. Check the RCA in memory `feedback_s3_crr_with_sse_kms_triple_gotcha`.

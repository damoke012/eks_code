# INFRA-1557 — S3 Cross-Region Replication for on-prem TF state

Self-serve TF module to enable CRR on `lazy-tf-state-65v583i6my68y6x9` (us-east-2, USX-Dev) replicating to a sibling bucket in us-west-2.

## Why self-serve, not Matt-handoff

Doke confirmed `AWSAdministratorAccess` permission set in USX-Dev (700736442855). No need to escalate to cloud-ops; we own the change end-to-end, ship it as IaC.

## What this module does

1. Creates destination bucket `lazy-tf-state-65v583i6my68y6x9-replica` in us-west-2
2. Enables versioning on **both** buckets (CRR prerequisite)
3. Creates IAM role for replication with minimal scoped policy
4. Applies `aws_s3_bucket_replication_configuration` on the source

## What it does NOT touch

- The source bucket's existing IAM policy, lifecycle rules, encryption — left as-is
- Any Terraform state in the bucket — state files copy automatically once CRR is enabled
- Any other buckets in the account

## Where this TF lives

**Open question for Doke**: where does the bootstrap TF for `lazy-tf-state-65v583i6my68y6x9` live today? Three options:

1. **Best**: append to wherever the source bucket is currently defined (one TF state, one source of truth)
2. **Acceptable**: create a small new TF module in `variant-inc/cloud-platform-tf` (or wherever cloud-ops state-bucket TF lives) and use a `data` source for the existing bucket
3. **Fallback**: standalone TF in `iaac-drafts/jun24-tf-state-crr/` for immediate apply, then refactor location

We'll use **option 3** for the apply, then Doke can decide where it should permanently live. The drift between draft location and canonical home is minor since CRR config doesn't change frequently.

## Files

- `versions.tf` — providers + versions
- `main.tf` — destination bucket + versioning + IAM + replication config
- `variables.tf` — minimal inputs
- `outputs.tf` — confirms what was created

## Apply runbook

```bash
cd ~/work/eks_code/iaac-drafts/jun24-tf-state-crr
export AWS_PROFILE=usx-dev
terraform init
terraform plan -out=plan.tfplan
# REVIEW the plan carefully:
#  - 1 new bucket in us-west-2
#  - 2 versioning configs (one per bucket)
#  - 1 IAM role + 1 policy
#  - 1 replication configuration
# Total: ~5 resources to add
terraform apply plan.tfplan

# Validate
aws --profile usx-dev s3api get-bucket-replication --bucket lazy-tf-state-65v583i6my68y6x9
aws --profile usx-dev s3api get-bucket-versioning --bucket lazy-tf-state-65v583i6my68y6x9
aws --profile usx-dev --region us-west-2 s3api get-bucket-versioning --bucket lazy-tf-state-65v583i6my68y6x9-replica

# Force a replication test by touching the state file
aws --profile usx-dev s3 cp s3://lazy-tf-state-65v583i6my68y6x9/iaac/talos/op-usxpress-dev.tfstate /tmp/state-test.tfstate
aws --profile usx-dev s3 cp /tmp/state-test.tfstate s3://lazy-tf-state-65v583i6my68y6x9/iaac/talos/op-usxpress-dev.tfstate

# Wait ~30 sec, then confirm replica
sleep 30
aws --profile usx-dev --region us-west-2 s3 ls s3://lazy-tf-state-65v583i6my68y6x9-replica/iaac/talos/
```

If the replica shows the same key, CRR is live.

## Close INFRA-1557

Edit `scratchpad/jun24-final-closeouts/close-1557.py`:

```python
OUTCOME = "doke_implemented"
IMPLEMENTATION_PR = ""  # if shipped to a TF repo, paste PR URL; if applied from iaac-drafts, paste git commit URL
```

Then `python3 close-1557.py` → comment + Done.

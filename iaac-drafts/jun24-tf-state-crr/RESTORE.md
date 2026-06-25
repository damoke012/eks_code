# Restore procedure — us-east-2 → us-west-2 failover

## When this applies

A real or simulated AWS us-east-2 S3 outage where `lazy-tf-state-65v583i6my68y6x9` is unreachable. Both states (cluster TF state + this module's own TF state) live in that bucket; both are replicated to us-west-2 via CRR.

This document describes how to **read** from us-west-2 during the outage. **Writes** while us-east-2 is down are non-trivial — see "Writing during outage" below.

## Pre-flight (do this once, BEFORE you need it)

Tested 2026-MM-DD by `<name>`. Repeat annually as a DR rehearsal.

```bash
# 1. Confirm replica has the on-prem cluster TF state
aws --profile usx-dev --region us-west-2 s3 ls \
  s3://lazy-tf-state-65v583i6my68y6x9-replica/iaac/talos/

# Should show op-usxpress-dev.tfstate with a recent LastModified.
# If empty, replication backfill of pre-CRR objects has not happened — see "Backfill" below.

# 2. Confirm you can decrypt replica objects with the destination CMK
aws --profile usx-dev --region us-west-2 s3 cp \
  s3://lazy-tf-state-65v583i6my68y6x9-replica/iaac/talos/op-usxpress-dev.tfstate \
  /tmp/dr-test-state.tfstate
# This implicitly uses the destination KMS key. If you see AccessDenied on KMS,
# your role lacks kms:Decrypt on the destination CMK — add it before you need it.
```

## During an outage — read-only access

### Get cluster TF state for read-only inspection

```bash
aws --profile usx-dev --region us-west-2 s3 cp \
  s3://lazy-tf-state-65v583i6my68y6x9-replica/iaac/talos/op-usxpress-dev.tfstate \
  /tmp/recovery-state.tfstate

# Extract credentials, machine secrets, talosconfig as needed
# This follows the same procedure as /onprem-safety Rule 6
```

### Get this module's own TF state (if you need to manage CRR while us-east-2 is down)

```bash
aws --profile usx-dev --region us-west-2 s3 cp \
  s3://lazy-tf-state-65v583i6my68y6x9-replica/iaac/state-dr/terraform.tfstate \
  /tmp/crr-module-state.tfstate
```

## Writing during outage

Writing TF state to the replica directly is **not supported** by default — the replica accepts only the replication role's writes, not regular `terraform apply`s. Two options:

### Option A — Wait for us-east-2 to come back (preferred)

Most us-east-2 outages historically resolve in <8 hours. The on-prem cluster continues to operate during this window — it does not depend on us-east-2 for runtime, only for recovery. Avoid making infrastructure changes; queue them for after recovery.

### Option B — Promote the replica bucket (requires manual intervention)

If the outage is prolonged or permanent (extremely rare):

1. **Stop replication** on the source bucket (so it doesn't try to re-overwrite the replica when us-east-2 returns):
   ```bash
   # ONLY do this if you've decided to promote permanently.
   # If us-east-2 comes back later, the source state will be STALE.
   aws --profile usx-dev s3api delete-bucket-replication \
     --bucket lazy-tf-state-65v583i6my68y6x9
   ```

2. **Reconfigure TF backend** to point at the replica directly (edit `backend.tf`):
   ```hcl
   terraform {
     backend "s3" {
       bucket         = "lazy-tf-state-65v583i6my68y6x9-replica"
       key            = "iaac/state-dr/terraform.tfstate"
       region         = "us-west-2"
       # Note: no dynamodb_table; lock table was in us-east-2 too. Lock is
       # disabled until you provision a replacement in us-west-2.
       encrypt        = true
     }
   }
   ```

3. **Migrate cluster TF** the same way: update its `backend.tf` to point at the replica's `iaac/talos/op-usxpress-dev.tfstate`.

4. **Communicate widely** before doing this — once the source is decommissioned, returning to us-east-2 requires another migration.

## Backfill — pre-CRR objects not in replica

CRR only replicates NEW writes after the rule is enabled. The on-prem cluster TF state file existed before CRR was set up; it stays in us-east-2 only until the next `terraform apply` against the cluster (which rewrites the state file and triggers replication).

To force-replicate the existing state without changing infrastructure:

```bash
# Touch the state file by re-uploading itself — creates a new version, triggers CRR
KEY="iaac/talos/op-usxpress-dev.tfstate"
aws --profile usx-dev s3 cp \
  s3://lazy-tf-state-65v583i6my68y6x9/$KEY \
  /tmp/backfill.tfstate
aws --profile usx-dev s3 cp /tmp/backfill.tfstate \
  s3://lazy-tf-state-65v583i6my68y6x9/$KEY

# Verify within 30 sec
sleep 30
aws --profile usx-dev --region us-west-2 s3 ls \
  s3://lazy-tf-state-65v583i6my68y6x9-replica/iaac/talos/
```

For a bulk backfill of every existing key, use S3 Batch Replication — see AWS docs. Don't run that without coordination; it can take hours and incurs cost.

## Related

- INFRA-1557 (this ticket) — the CRR enablement
- [[onprem-safety]] Rule 6 — talosctl recovery from S3 tfstate
- [[incident_2026_06_17_cp_oom_cascade]] — proves the recovery path uses S3 read

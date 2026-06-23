# Advisory: cross-region replication for `lazy-tf-state-65v583i6my68y6x9`

**For**: Cloud team (owners of the TF state bucket)
**Filed by**: Doke, Cloud Platform — Knight-Swift Cloud Platform team
**Created**: 2026-06-23

## TL;DR

The S3 bucket `lazy-tf-state-65v583i6my68y6x9` (us-east-2, USX-Dev account 700736442855) holds the Terraform state for op-usxpress-dev cluster. **It's the single point of recovery for "rebuild cluster from scratch" scenarios.**

If this bucket is deleted, corrupted, or lost to a regional AWS event, the talosconfig + Talos machine config + IRSA OIDC discovery are unrecoverable except by rebuilding the cluster from manual machine config.

Request: enable AWS S3 cross-region replication (CRR) to a secondary region, OR daily versioned snapshot to a backup bucket in a different region.

## Why this matters

We validated tonight (2026-06-23 restore-readiness audit) that:

- ✅ Velero PVC + namespace backups are operational and tested (restore verified)
- ✅ etcd snapshots are written to S3 hourly (`s3://etcd-snapshots-op-usxpress-dev/`)
- ✅ Cluster TF (iaac-talos `feature/op-usxpress-dev`) describes how to rebuild VMs, install Talos, install Cilium, install Flux
- ⚠️ All of this depends on tfstate at `lazy-tf-state-65v583i6my68y6x9` being accessible

The recovery sequence for "we lost the cluster but Velero backups + etcd snapshots exist" is:

1. Pull tfstate from this bucket (per onprem-safety skill Rule 6 recovery path)
2. Extract talosconfig + Talos machine secrets
3. Terraform apply iaac-talos → rebuild VMs + reinstall Talos
4. Flux bootstrap (manual; documented in runbook)
5. Velero restore for namespace state
6. etcd snapshot restore for etcd state (if etcd was lost)

**Step 1 is the critical dependency.** Without tfstate, steps 2-6 are blocked.

## Existing protections (what's already in place)

`lazy-tf-state-65v583i6my68y6x9` already has:
- Versioning enabled (per AWS S3 default for tfstate)
- Server-side encryption (per AWS S3 default)
- Account-scoped access via the usx-dev SSO profile

But these protect against accidental delete/overwrite within the account. They don't protect against:
- Bucket deletion (versioning doesn't survive bucket delete)
- Regional AWS event (us-east-2 unavailable)
- Account credential compromise (deletes possible)
- Whoever runs `aws s3 rb` with `--force`

## Requested mitigation

Choose any ONE of:

### A) AWS S3 Cross-Region Replication (CRR)
- Replicate to a peer region (us-west-2 or us-east-1)
- Automatic, near-real-time
- Use a separate IAM role for replication
- Cost: ~$0.02/GB stored in destination + small per-object replication fee

### B) Daily snapshot via lifecycle to a backup bucket
- Use S3 Batch Operations or a Lambda triggered cronjob
- Copy all objects daily to a separate bucket (preferably in a different region OR a different account)
- Cost: storage in 2nd bucket + Lambda invocations

### C) Multi-region same-account (cheapest)
- Use Bucket Cloning or terraform-state-rotator
- Daily Terraform-driven backup
- Doesn't protect against account compromise, but covers regional events

## Impact on our team

Today: 0 — we don't have direct access to write replication policies on this bucket.

Future: any cluster recovery exercise we run depends on this bucket being intact. We're treating it as a SHARED responsibility — cloud team owns the bucket, we own the cluster.

## Asking

Cloud team to:
1. Add cross-region or cross-account replication to `lazy-tf-state-65v583i6my68y6x9` (or document existing replication if it's already there)
2. Confirm bucket has MFA-delete enabled OR is in a "guarded" policy state
3. Send back the recovery RPO/RTO for tfstate (we need to know for our SLA targets)

If this already exists, just point us at the docs and we'll close this advisory.

## Related

- onprem-safety skill Rule 6 — talosconfig recovery from tfstate
- session_state_jun23.md — restore-readiness audit details
- iaac-talos `feature/op-usxpress-dev` — the TF code that depends on this state

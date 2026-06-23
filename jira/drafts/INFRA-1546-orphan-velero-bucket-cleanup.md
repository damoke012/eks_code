# INFRA-1546: Delete orphan `velero-data20251003174153662900000001` S3 bucket

**Type**: Task / Housekeeping
**Priority**: Low
**Component**: AWS / Backup infra
**Reporter**: Doke
**Created**: 2026-06-23

## Problem

S3 bucket `velero-data20251003174153662900000001` exists in the USX-Dev account (700736442855). Created 2026-04-28 (per `aws s3 ls`).

The naming pattern (UUID-suffixed) suggests it was provisioned by a prior abandoned Velero attempt — possibly via a Helm chart that auto-generates bucket names, or a Terraform run that wasn't tracked in our iaac-talos tfstate.

Not currently referenced by any IaC. Not in iaac-talos state. Not in any HelmRelease values.

## Scope

1. **Verify the bucket is truly orphan**: check S3 bucket policy / tagging / who created it (CloudTrail). Confirm no production workloads reference it.
2. **Check contents**: if empty, delete. If non-empty, archive or confirm with team before delete.
3. **Document**: if there's a service that DOES reference it (we don't think so but let's verify), add it to iaac-talos.

## Acceptance criteria

- Bucket deleted OR documented in iaac-talos with proper TF resource
- AWS console + `aws s3 ls --profile usx-dev | grep velero` shows ONLY our intentional buckets:
  - `velero-op-usxpress-dev`
  - (future) `velero-op-usxpress-qa` (when QA cluster comes up)

## Constraints

- **Don't delete WITHOUT verifying it's truly orphan first** — Tim, cloud team, or other infra may use it
- Use a soft-delete: enable bucket versioning OR move objects to Glacier before final delete

## Estimate

~30 min (verification + delete or document)

## Refs

- 2026-06-23 restore-readiness audit during `aws s3 ls` enumeration
- The intentional new bucket `velero-op-usxpress-dev` was created by iaac-talos PR #44 with deterministic naming

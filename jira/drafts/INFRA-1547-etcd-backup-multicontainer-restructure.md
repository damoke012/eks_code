# INFRA-1547: Restructure etcd-backup CronJob — multi-container pattern

**Type**: Bug / Refactor
**Priority**: Medium (Velero now covers PVC/namespace restore; etcd-backup is full-disaster-only)
**Component**: etcd-backup / Talos
**Reporter**: Doke
**Created**: 2026-06-23

## Problem

The etcd-backup CronJob in `infrastructure/etcd-backup/cronjob.yaml` (iaac-talos-flux-platform) uses a single container with:

```yaml
image: ghcr.io/siderolabs/talosctl:v1.10.4
command:
  - /bin/sh
  - -c
  - |
    set -euo pipefail
    talosctl --talosconfig=... etcd snapshot ${OUT}
    apk add --no-cache aws-cli 2>/dev/null || true
    aws s3 cp ${OUT} s3://${S3_BUCKET}/...
```

This fails at container init because the Sidero talosctl image is **distroless** — it has only the `/talosctl` binary, no `/bin/sh`, no `apk`, no `aws`:

```
exec: "/bin/sh": stat /bin/sh: no such file or directory
```

Job fails. CronJob fails silently every hour. Talos auto-snapshots etcd locally on each CP (`/var/lib/etcd/snapshot.db`) so we're not COMPLETELY uncovered, but S3 externalization for full-disaster recovery doesn't work.

## Why deferred from 2026-06-23

Velero's PVC backup (the bigger restore-readiness win) was already working. Restructuring etcd-backup requires either a custom fat image (CI build) OR a multi-container pod redesign. Both 20-30 min of work. We chose to defer in favor of QA bring-up momentum.

## Scope

Pick ONE of:

### Option A — Multi-container (recommended; no CI build)

- initContainer: `ghcr.io/siderolabs/talosctl:v1.10.4` runs `/talosctl etcd snapshot /work/snapshot.db`
- main container: `amazon/aws-cli:2.17.0` uploads `/work/snapshot.db` to S3
- Shared emptyDir for the snapshot file
- Pod-level seccompProfile, fsGroup=1000 so both containers can access /work

Sample spec in catalog entry: `04-secrets-credentials/talosctl-image-distroless.md`

### Option B — Custom fat image

- Build `amazonlinux:2023` base + talosctl + aws CLI
- Push to ECR (variant-inc/iaac-talos-images?)
- Single container in CronJob references the ECR image

Better for reuse if we need similar tooling for other CronJobs (Cilium dumps, ceph backups, etc.). Worse for one-off use.

## Acceptance criteria

- `kubectl -n etcd-backup create job --from=cronjob/etcd-snapshot-to-s3 test-snapshot` completes successfully
- S3 bucket `s3://etcd-snapshots-op-usxpress-dev/op-usxpress-dev/<timestamp>/snapshot.db` has the file with non-zero size
- Hourly CronJob runs without failure for at least 24h
- A test restore (extract snapshot.db, validate with `talosctl etcd snapshot inspect`) succeeds

## Constraints

- Don't enable for QA cluster bring-up until validated on op-usxpress-dev
- PSA `restricted` enforce stays on (don't downgrade for convenience) — see `[`psa-restricted-seccomp-required.md`](../iaac-drafts/jun23-catalog-batch/04-secrets-credentials/psa-restricted-seccomp-required.md)`

## Estimate

~30 min for Option A; ~2 hours for Option B (includes CI/ECR setup)

## Refs

- session_state_jun23.md — deferred during close-every-gap marathon
- Catalog entry: `iaac-drafts/jun23-catalog-batch/01-cluster-control-plane/talosctl-image-distroless.md`
- [`feedback-talosctl-image-distroless`](../../memory/feedback_talosctl_image_distroless.md)
- INFRA-1541 (original etcd-backup setup ticket) — parent

# Close Dev gaps — 2026-06-22 final IaC push

**Goal:** Close the high-value gaps from the restore-readiness audit. After this round, Dev is as IaC-restore-ready as it can be without standing up Octopus/Velero/etcd-backup-restore tests (which are operational tasks for next sessions).

## 4 PRs

### PR-N (iaac-talos-flux-platform op-dev) — Velero + etcd-backup + pod-identity-webhook HA + catalog

**Changes:**

| File | Action |
|---|---|
| `infrastructure/velero/namespace.yaml` | NEW |
| `infrastructure/velero/helmrepository.yaml` | NEW |
| `infrastructure/velero/serviceaccount.yaml` | NEW |
| `infrastructure/velero/helmrelease.yaml` | NEW |
| `infrastructure/velero/kustomization.yaml` | NEW |
| `infrastructure/etcd-backup/namespace.yaml` | NEW |
| `infrastructure/etcd-backup/serviceaccount.yaml` | NEW |
| `infrastructure/etcd-backup/talosconfig-externalsecret.yaml` | NEW |
| `infrastructure/etcd-backup/cronjob.yaml` | NEW |
| `infrastructure/etcd-backup/kustomization.yaml` | NEW |
| `infrastructure/pod-identity-webhook/deployment.yaml` | EDIT — replicas 1→2 + rolling strategy + anti-affinity |

**Important:** Velero + etcd-backup will go Ready=True ONLY after the iaac-talos terraform PR for IAM roles is merged + applied. Until then:
- Velero HelmRelease will install but fail to authenticate to S3
- etcd-backup CronJob will run but fail on aws s3 cp

This is acceptable; the IaC structure is correct. Operational standup happens when iaac-talos terraform runs.

### PR-O (iaac-talos-flux-cluster master) — Flux Kustomizations for Velero + etcd-backup

Append 2 new Kustomization blocks at end of `clusters/bm-dev/flux-system/infra.yaml`:
- `velero` (wait: true, dependsOn external-secrets-config + pod-identity-webhook)
- `etcd-backup` (wait: true, dependsOn external-secrets-config + pod-identity-webhook)

### PR-P (iaac-talos feature/op-usxpress-dev) — IAM roles + S3 buckets

**File:** `iam-backup.tf` (or wherever your iam modules live)

Adds:
- 2 IAM roles (`op-usxpress-dev-velero`, `op-usxpress-dev-etcd-backup`) with IRSA trust
- 2 S3 buckets (`velero-op-usxpress-dev`, `etcd-snapshots-op-usxpress-dev`)
- Lifecycle policies (30d retention)

Plan + apply via Octopus (TfApply=true).

### PR-Q (iaac-talos feature/op-usxpress-dev catalog) — 2 new catalog entries

| File | Content |
|---|---|
| `deploy/docs/troubleshooting/02-storage/cephcluster-monitoring-enabled-rbac.md` | NEW — RBAC stall pattern, fix via removing `monitoring.enabled` |
| `deploy/docs/troubleshooting/06-incidents-timeline/flux-source-bump-cascade.md` | NEW — flux source-bump race + force-reconcile remedy |

Also: append the new catalog entries to the README symptom-index.

## Operational steps AFTER all 4 PRs merge

1. **Seed talosconfig to AWS SM** (one-time per cluster):
   ```bash
   aws secretsmanager create-secret \
     --name op-usxpress-dev/talosconfig \
     --secret-string file:///tmp/talosconfig-op-usxpress-dev \
     --profile usx-dev
   ```

2. **Verify Velero**:
   ```bash
   kubectl -n velero get pods
   kubectl -n velero get backupstoragelocation
   velero backup get  # may need: brew install velero or kubectl exec
   ```

3. **Manually trigger first etcd snapshot to verify**:
   ```bash
   kubectl -n etcd-backup create job --from=cronjob/etcd-snapshot-to-s3 manual-verify
   kubectl -n etcd-backup logs job/manual-verify
   aws s3 ls s3://etcd-snapshots-op-usxpress-dev/op-usxpress-dev/ --profile usx-dev
   ```

4. **Verify pod-identity-webhook HA**:
   ```bash
   kubectl -n pod-identity-webhook get pods   # should show 2 Running
   ```

## Out of scope (deferred — multi-session)

- INFRA-1542 Flux bootstrap automation — scaffold drafted at `terraform/flux-bootstrap/`. Standing up the actual module needs careful provider testing.
- INFRA-1543 OnPremise Octopus space — already scaffolded earlier tonight at `iaac-drafts/tracks-4-5-restore-jun22/octopus-onprem-scaffold/`. Needs Octopus admin token.
- Full nuke + rebuild test — destructive, requires planned maintenance window.
- Restore-from-Velero test — needs Velero deployed + actual backup + restore drill.

## Acceptance criteria after this round

- INFRA-1540 Velero deployed (IaC + actual deployment via Flux)
- INFRA-1541 etcd snapshots externalized (IaC + first manual job verified)
- pod-identity-webhook HA
- 2 new catalog entries shipped

Tickets to close after PR merges + verification:
- INFRA-1540 → Done (after Velero pod 1/1 Ready + S3 backup directory created)
- INFRA-1541 → Done (after first manual etcd snapshot Job succeeds + S3 has file)

INFRA-1542/1543 stay In Progress (scaffolds drafted).

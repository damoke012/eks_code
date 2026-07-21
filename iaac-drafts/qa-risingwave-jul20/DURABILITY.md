# RisingWave on QA — surviving a teardown

**Context:** RW has never been deployed to QA (confirmed 2026-07-20: no
`manifests/op-usxpress-qa`, no `op-usxpress-qa-risingwave` IAM role, no
`op-usxpress-qa/risingwave/*` secrets). So durability gets designed in, not bolted on.

**The core fact:** a PVC does NOT survive a cluster teardown. PVCs are backed by cluster
storage (Rook-Ceph / local-path); destroying the cluster destroys them. Persistence
across a rebuild comes from S3 + Velero, not from adding a PVC.

## What RisingWave stores

| Data | Location | Survives teardown? |
|---|---|---|
| Streaming state (bulk of the data) | S3 `risingwave-state-op-usxpress-qa` | ✅ if bucket excluded from `terraform destroy` |
| Metastore catalog | Postgres PVC, in-cluster | ❌ unless backed up off-cluster |
| Compute cache | ephemeral | ❌ and irrelevant |

## 1. Fix the StorageClass (dev is wrong — don't copy it)

Dev runs the metastore on **`local-path`**:
```
risingwave  data-postgres-postgresql-0  10Gi  RWO  local-path  49d
```
Node-local disk: not replicated, lost if that node dies — no teardown required. QA is a
Prod-standard mirror, so use replicated storage.

In `postgres-helmrelease.yaml`:
```yaml
  values:
    primary:
      persistence:
        enabled: true
        size: 20Gi
        storageClass: ceph-block      # NOT local-path
```

## 2. Velero schedule for the metastore

This is what actually carries data across a rebuild. Velero is already in the platform
stack with bucket `velero-op-usxpress-qa`.

`manifests/op-usxpress-qa/velero-schedule.yaml`:
```yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: risingwave-metastore
  namespace: velero
spec:
  schedule: "0 */6 * * *"          # every 6h
  template:
    includedNamespaces: [risingwave]
    includedResources:
      - persistentvolumeclaims
      - persistentvolumes
      - secrets
    snapshotVolumes: true
    defaultVolumesToFsBackup: true  # Ceph RBD has no native Velero snapshotter here
    ttl: 720h                       # 30d retention
```
Verify after first run: `velero backup get` shows `Completed`, not `PartiallyFailed`.

## 3. Protect the S3 state store at teardown

Add `risingwave-state-op-usxpress-qa` to the `terraform state rm` list in
`REBUILD-RUNBOOK.md` §1, alongside `velero-*` and `etcd-snapshots-*`:
```bash
terraform state rm 'module.irsa[0].aws_s3_bucket.velero' \
  'module.irsa[0].aws_s3_bucket.etcd_snapshots' \
  'module.irsa[0].aws_s3_bucket.risingwave_2_data'
# + the risingwave-state bucket once it exists in the RW repo's own state
```
⚠️ The RW state bucket lives in **`iaac-risingwave-onprem`'s** Terraform state, not
iaac-talos's — so it is NOT touched by an iaac-talos destroy. Confirm that separation
holds rather than assuming it.

## 4. Add the restore step to the rebuild runbook

The runbook currently claims "100% IaC, zero manual". With RW in the platform stack that
stops being true unless a restore step exists. Add to §2, after Flux reconciles:

```bash
# restore the RW metastore from the last good backup
velero restore create --from-backup $(velero backup get -o name | head -1) \
  --include-namespaces risingwave
kubectl -n risingwave rollout status statefulset/postgres-postgresql
```
Then re-verify RW comes up healthy against the restored metastore + preserved S3 state.

## 5. Alternative worth considering

Moving the metastore to **RDS** removes it from cluster state entirely — no PVC, no
Velero dependency, survives teardown by construction. More upfront work, but for a
Prod-standard environment it is the cleaner answer, and it deletes items 1, 2 and 4
above. Decide before Idris writes the manifests, because it changes
`postgres-helmrelease.yaml` and `risingwave-cr.yaml` materially.

## Open decision

**Velero (items 1–4) vs RDS metastore (item 5).** This must be settled before the
manifests are written — retrofitting means migrating a live metastore.

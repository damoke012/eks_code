---
name: eso-secretsynced-not-content-check
description: ExternalSecret SecretSynced/READY=True proves only that ESO fetched and wrote a value — it says nothing about whether the value is valid. Placeholders sync green.
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 161fed6b-7af8-49e8-9abf-c06ed6494c28
  modified: 2026-07-21T16:19:31.146Z
---

An ExternalSecret showing `SecretSynced` / `READY=True` means **ESO reached AWS SM and wrote a k8s Secret**. It is **not** a content check. Garbage in SM syncs green.

**Why:** hit twice in two days, both times costing real debugging because green status read as "working":
1. **Wiz sensor** (`op-usxpress-dev`) — `wiz-api-token` + `sensor-image-pull` both `SecretSynced True` while SM held the literal placeholder `<real>`; all 7 pods sat in `ImagePullBackOff` (fast 401 on `wizio.azurecr.io`). See [[wiz-sensor-onprem-dev]].
2. **etcd-backup** (`op-usxpress-qa`, 2026-07-21) — `talosconfig` ExternalSecret `SecretSynced True`, but SM held `PLACEHOLDER_POPULATE`; hourly `etcd-snapshot-to-s3` failed **every run for 13 days → zero etcd snapshots on QA**. Filed as INFRA-1623. See [[qa-cluster-standup]].

**How to apply:** never treat `SecretSynced` as proof a secret works. Verify **content** without printing it:
```bash
# AWS SM side — key names + character counts only, never values
aws secretsmanager get-secret-value --profile <p> --secret-id <id> --query SecretString --output text \
  | jq -r 'to_entries[] | "\(.key): \(.value|length) chars"'
# k8s side — first bytes only, enough to spot a placeholder (mind the KEY NAME:
# ESO's secretKey often differs from the SM secret name, e.g. SM op-usxpress-qa/talosconfig -> key `config`)
kubectl -n <ns> get secret <name> -o jsonpath='{.data.<key>}' | base64 -d | head -c 20; echo
```
Uniform short lengths (every field 6 chars = `<real>`) or a `PLACEHOLDER`/`REAL` prefix means it was never populated. Cross-check `LastChangedDate` on the SM secret to see whether the real owner has written yet. Related: [[usx-github-enterprise-not-personal]].

**Third and fourth instances, 2026-08-20 (op-usxpress-qa):**
* Four consumers reported `SecretSynced` on a Postgres password the database had never
  accepted — see [[qa-postgres-password-drift]]. Sync status cannot see the far end.
* Argo CD reported `Synced Healthy` while the Job it had just created sat in
  `ImagePullBackOff`. Sync status means "manifests match git"; it is not a statement about
  the workload.

The check that answers it: `scripts/check-postgres-secret-usable.sh` — it authenticates,
rather than reading a status field.

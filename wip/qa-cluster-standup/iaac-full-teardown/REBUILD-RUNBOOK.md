# op-usxpress-qa — full teardown + rebuild runbook (CLI, IaC-only)

**Goal:** destroy QA completely and rebuild it 100% from IaC with no manual
cluster surgery. After the `secrets-values.tf` change lands, the only thing a
from-scratch rebuild cannot self-generate is the **real Azure-AD app-registration
secret** (Entra-owned; grafana still boots with a placeholder and admin login).

Everything else — Talos, Flux, IRSA (roles/OIDC/CloudFront/buckets), storage
(Rook/local-path), all platform Kustomizations, talosconfig value, grafana admin
password — is recreated automatically.

---

## Prereqs (one-time, already done once the value-writes change is deployed)
- iaac-talos refactor branch has: grafana wrappers + import blocks, `secrets-values.tf`,
  `manage_platform_secret_values`, `recovery_window_in_days = 0`, `hashicorp/random`.
- Octopus QA vars set: `TF_VAR_enable_irsa=true`, `TF_VAR_irsa_oidc_bucket_name`,
  `TF_VAR_grafana_admin_secret_arn`, `TF_VAR_grafana_azure_ad_secret_arn`,
  `TF_VAR_manage_platform_secret_values=true`, + the 26 base QA vars.
- Flux: op-qa branch (platform manifests) + `clusters/op-usxpress-qa` (cluster repo)
  are the current, correct source of truth.

---

## 1. TEARDOWN

⚠️ Decisions before you destroy:
- **Data buckets** (`velero-op-usxpress-qa`, `etcd-snapshots-op-usxpress-qa`,
  `risingwave-data-op-usxpress-qa`) hold backups/data. A full destroy deletes them.
  To KEEP backups across the rebuild, `terraform state rm` those bucket resources
  before destroy (they survive, unmanaged) or snapshot them first.
- `recovery_window_in_days = 0` means the SM secrets delete immediately (so the
  rebuild can recreate same-named secrets without the 7-day block).

```bash
cd ~/work/iaac-talos/deploy/terraform
export AWS_PROFILE=usx-qa
aws sso login --profile usx-qa

terraform init -reconfigure \
  -backend-config="bucket=lazy-tf-state-425rbol87rmn6c7m" \
  -backend-config="key=iaac/talos/op-usxpress-qa.tfstate" \
  -backend-config="region=us-east-2" \
  -backend-config="dynamodb_table=lazy_tf_state" \
  -backend-config="encrypt=true"

# (optional) preserve data buckets across the rebuild:
# terraform state rm 'module.irsa[0].aws_s3_bucket.velero' \
#   'module.irsa[0].aws_s3_bucket.etcd_snapshots' 'module.irsa[0].aws_s3_bucket.risingwave_2_data'

# DESTROY — needs the same vars Octopus injects. Supply vsphere/github creds via
# a private tfvars or -var flags (same set used for plan). enable_irsa MUST be true.
terraform destroy \
  -var-file=envs/qa.tfvars \
  -var-file=envs/qa.secret.tfvars      # or -var flags for vsphere_*/github_token/etc.
```

> Octopus-only note: routine changes go through Octopus. A deliberate full
> teardown is the exception; if a `Destroy op-usxpress-qa` Octopus runbook exists,
> prefer it. Otherwise this guarded local destroy is the mechanism.

After destroy: `terraform state list` is empty; the tfstate bucket + DynamoDB lock
remain (they're bootstrap infra, not managed here).

---

## 2. REBUILD (via Octopus — the normal apply path)

```bash
# Ensure the release captures the current variable snapshot (create fresh if unsure):
octopus release create --project "iaac-talos" --space "DevOps" --channel feature \
  --package-version "<latest-pkg-version>" --no-prompt
octopus release list --project "iaac-talos" --space "DevOps" | head -3   # note the version

# Deploy to qa — Octopus runs terraform apply (CP+workers -> bootstrap -> Flux ->
# IRSA -> JWKS upload -> SSM/SA -> SM secret values).
octopus release deploy --project "iaac-talos" --space "DevOps" \
  --version <version> --environment qa --no-prompt
```

This single apply reconstructs, in order (per QA-CLUSTER-BOOTSTRAP-CHECKLIST):
1. Talos CP + workers, etcd quorum, talosconfig/kubeconfig -> tfstate
2. IRSA: OIDC bucket + CloudFront + provider, all 10 roles, JWKS upload
3. SM secret VALUES: talosconfig (real), grafana admin (random), grafana azure-ad (placeholder)
4. Flux bootstrap -> reconciles op-qa: cert-manager, istio, external-secrets,
   local-path, Rook-Ceph, prometheus, grafana, velero, etcd-backup, external-dns

No manual kubectl. Flux + ESO pull everything from git + AWS SM.

---

## 3. VERIFY (all automatic)

```bash
# cluster
kubectl get nodes                                   # 13 Ready
flux get kustomizations -A | grep -v True | cat     # only headers => all Ready
# storage
kubectl -n rook-ceph get cephcluster                # HEALTH_OK
kubectl get sc                                      # local-path + ceph-block/fs/bucket
# secrets self-seeded
aws --region us-east-2 secretsmanager get-secret-value --secret-id op-usxpress-qa/talosconfig \
  --query SecretString --output text | head -c 20   # real talosconfig, NOT PLACEHOLDER
kubectl get externalsecret -A | grep -v True | cat  # all SecretSynced
kubectl -n grafana get pods                         # Running (admin pw from SM)
# etcd-backup works with the real talosconfig
kubectl -n etcd-backup create job --from=cronjob/etcd-backup verify-$(date +%s)
kubectl -n etcd-backup logs -l job-name --tail=30   # snapshot uploaded to S3
# retrieve the freshly-generated grafana admin password
aws --region us-east-2 secretsmanager get-secret-value \
  --secret-id op-usxpress-qa/platform/grafana --query SecretString --output text
```

---

## 4. The ONE external step (optional — only for Azure SSO)

Grafana runs fine on admin login without this. To enable Azure-AD SSO, inject the
real Entra app-registration creds (someone with Entra access):
```bash
aws --region us-east-2 secretsmanager put-secret-value \
  --secret-id op-usxpress-qa/platform/grafana/azure-ad \
  --secret-string '{"client_id":"<real>","client_secret":"<real>"}'
kubectl -n grafana annotate externalsecret grafana-azure-ad-creds force-sync="$(date +%s)" --overwrite
kubectl -n grafana rollout restart deploy grafana
```
`ignore_changes` on the TF placeholder means this real value survives future applies.

---

## Summary
- **Cluster + platform + storage + IRSA + talosconfig + grafana admin** → 100% IaC, zero manual.
- **Azure-AD SSO creds** → the single external secret (grafana works without it).
- **Data buckets** → decide keep-vs-destroy before teardown (state rm to keep).

# Codify grafana SM secrets + fix enable_irsa landmine — apply guide (2026-07-14)

Makes QA's secret layer fully IaC so a teardown+rebuild needs zero manual steps.
INFRA-1589. Two repos: iaac-talos (Terraform via Octopus) + flux op-qa (external-dns).

## 0. Run the edit script + review
```bash
bash ~/work/eks_code/wip/qa-cluster-standup/apply-irsa-grafana-codify.sh   # adjust path if needed
cd ~/work/iaac-talos
git diff                      # eyeball every hunk
terraform -chdir=deploy/terraform fmt
terraform -chdir=deploy/terraform validate
```
Expected diff: new `modules/irsa/grafana-secret.tf`, new `grafana-secret-import.tf`,
+2 vars in `variables.tf` (root & module), 2 lines in `main.tf` module block,
qa.tfvars (enable_irsa→true, bucket, real talosconfig ARN, +2 grafana ARNs),
dev.tfvars (+2 grafana ARNs).

## 1. LOCAL PLAN — must show ONLY 2 grafana imports + ZERO destroy
IRSA is already in state at enable_irsa=true, so flipping qa.tfvars to true MATCHES
state (no IRSA diff). The only change is adopting the 2 hand-made grafana secrets.

```bash
cd ~/work/iaac-talos/deploy/terraform
export AWS_PROFILE=usx-qa
aws sts get-caller-identity >/dev/null 2>&1 || aws sso login --profile usx-qa

terraform init -reconfigure \
  -backend-config="bucket=lazy-tf-state-425rbol87rmn6c7m" \
  -backend-config="key=iaac/talos/op-usxpress-qa.tfstate" \
  -backend-config="region=us-east-2" \
  -backend-config="dynamodb_table=lazy_tf_state" \
  -backend-config="encrypt=true"

# supply the vsphere/github secret vars the same way you did for the Dev empty-diff.
# If you have a gitignored envs/qa.secret.tfvars, add: -var-file=envs/qa.secret.tfvars
terraform plan -var-file=envs/qa.tfvars [-var-file=envs/qa.secret.tfvars] -out=qa-irsa.tfplan
```

**GATE — read the plan summary. Proceed ONLY if:**
- `import` blocks: `module.irsa[0].aws_secretsmanager_secret.grafana_admin[0]` and
  `…grafana_azure_ad[0]` → **will be imported**
- Plan shows **0 to destroy, 0 to replace** (creates limited to net-new like the
  grafana secret_version if you add item D later; NO destroys)
- No `module.irsa[0].*` marked for destroy (that would mean enable_irsa didn't take)

If anything shows destroy/replace of an IRSA role/OIDC/bucket → STOP, do not apply.

## 2. Add the Octopus TF_VARs (MANDATORY — Octopus drives the real apply)
Octopus deploys from `TF_VAR_*` (env.auto.tfvars), NOT from -var-file. So qa.tfvars
alone won't reach the apply — without these two vars the Octopus apply tries to
CREATE the grafana secrets and fails ("already exists"). The count-gate makes the
absence safe (no-op), but to actually ADOPT them, Octopus must pass the ARNs.

Add to the QA-scoped project variables (DevOps space, iaac-talos project):
```
TF_VAR_grafana_admin_secret_arn    = arn:aws:secretsmanager:us-east-2:527101283767:secret:op-usxpress-qa/platform/grafana-FMI2a9
TF_VAR_grafana_azure_ad_secret_arn = arn:aws:secretsmanager:us-east-2:527101283767:secret:op-usxpress-qa/platform/grafana/azure-ad-8PBQhR
```
(Also confirm TF_VAR_enable_irsa=true and TF_VAR_irsa_oidc_bucket_name=op-usxpress-qa-irsa-oidc-v2
already exist — they must, since IRSA is in state.) Use the same mechanism as
`octopus-qa-env-setup/add-qa-vars.py`; ask Claude to extend that script for these 2.

## 3. Commit + push (refactor branch) + deploy via Octopus
```bash
cd ~/work/iaac-talos
git add deploy/terraform
git commit -m "INFRA-1589: codify grafana SM wrappers in modules/irsa + fix qa.tfvars enable_irsa landmine

- grafana-secret.tf: count-gated SM wrappers (grafana admin + azure-ad), talosconfig pattern
- root import blocks adopt the hand-seeded op-usxpress-qa grafana secrets (0 destroy)
- qa.tfvars: enable_irsa false->true (matched live state; false was a destroy landmine),
  real irsa_oidc_bucket_name + talosconfig ARN, + grafana ARNs
- dev.tfvars: Dev grafana ARNs so the shared-module change adopts (not recreates) on Dev"
git push
```
Then deploy the QA release via Octopus (DevOps space, env qa). Its plan step uses the
injected TF_VARs; confirm the plan matches the local one (2 imports, 0 destroy) before
it applies.

## 4. Verify post-apply
```bash
export AWS_PROFILE=usx-qa
terraform -chdir=deploy/terraform state list | grep grafana   # 2 wrappers now in state
aws --region us-east-2 secretsmanager describe-secret --secret-id op-usxpress-qa/platform/grafana --query Tags
# ESO still green, grafana still Running (adoption changes nothing live):
kubectl get externalsecret -n grafana
kubectl -n grafana get pods
```

## external-dns txtOwnerId dev->qa (flux op-qa, GitOps) — do alongside
```bash
cd ~/work/iaac-talos-flux-platform
git checkout op-qa && git pull
sed -i 's#txtOwnerId: iaac-talos/us-east-2/op-usxpress-dev#txtOwnerId: iaac-talos/us-east-2/op-usxpress-qa#' \
  infrastructure/external-dns/release.yaml
git diff
git add infrastructure/external-dns/release.yaml
git commit -m "INFRA-1589: external-dns txtOwnerId op-usxpress-dev -> op-usxpress-qa (QA claimed dev DNS ownership)"
git push origin op-qa
# then on QA context:
flux reconcile source git infra
kubectl -n external-dns rollout restart deploy external-dns   # picks up new txtOwnerId
```

## Item D — talosconfig VALUE (separate, careful): still PLACEHOLDER
etcd-backup ES syncs a placeholder → CronJob would fail. No TF resource writes it.
Fix = add `aws_secretsmanager_secret_version.talosconfig` fed by a `talos_client_configuration`
data source (endpoints = CP IPs), so TF writes the real talosconfig on every apply
(matches the checklist "TF manages talosconfig" principle) → rebuild-clean. Needs the
talos module wiring reviewed first; do as the next change, validate by running the
etcd-backup Job and confirming a snapshot lands in S3.

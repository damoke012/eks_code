# Item D — TF writes the real talosconfig value (fix etcd-backup) — INFRA-1589

**Do this AFTER .202 (grafana codify) is confirmed clean.** It changes a secret
VALUE, so keep it a separate commit + deploy, and validate by running the
etcd-backup Job.

## Why
QA `op-usxpress-qa/talosconfig` value = literal `PLACEHOLDER_POPULATED_BY_TERRAFORM_ON_FI…`.
No `aws_secretsmanager_secret_version` ever existed — TF only made the wrapper.
So etcd-backup's ExternalSecret syncs a placeholder → the CronJob would fail.
`talosconfig-secret-version.tf` adds the version, fed by `talos_client_configuration`.

## Apply (iaac-talos refactor branch)
```bash
cp ~/work/eks_code/wip/qa-cluster-standup/iaac-talosconfig-value/talosconfig-secret-version.tf \
   ~/work/iaac-talos/deploy/terraform/talosconfig-secret-version.tf   # or paste inline
cd ~/work/iaac-talos/deploy/terraform
terraform fmt && terraform validate
```

## Verify the data source resolves + plan is safe (targeted, dummy vsphere vars)
```bash
export AWS_PROFILE=usx-qa
terraform plan -var-file=envs/qa.tfvars \
  -target='aws_secretsmanager_secret_version.talosconfig[0]' \
  -var vsphere_user=x -var vsphere_password=x -var vsphere_server=x \
  -var github_token=x -var datacenter=x -var datastore=x \
  -var vm_cluster_name=x -var vm_folder=x -var network_name=x \
  -var content_library_name=x -var content_library_item_name=x
```
NOTE: a targeted local plan may fail to compute `module.vsphere_cp.ip_addresses`
with dummy vsphere creds (it reads live VM IPs). If so, DON'T force it locally —
let the Octopus deploy compute it (it has real vsphere access). Expected in the
Octopus plan: `aws_secretsmanager_secret_version.talosconfig[0]` will be **created**
(writes the real talosconfig), everything else unchanged, 0 destroy.

## Ship + validate
```bash
cd ~/work/iaac-talos && git add deploy/terraform/talosconfig-secret-version.tf
git commit -m "INFRA-1589: TF writes real talosconfig SM value (fix etcd-backup placeholder)"
git push
# new release auto-builds -> deploy to qa (watch plan: +1 create, 0 destroy)
```
After apply, confirm the value is real + etcd-backup works:
```bash
aws --region us-east-2 secretsmanager get-secret-value \
  --secret-id op-usxpress-qa/talosconfig --query SecretString --output text | head -c 40; echo
# expect a real talosconfig (context:/contexts:/…), NOT PLACEHOLDER

# force the ES to resync + run the etcd-backup job on-demand
kubectl -n etcd-backup annotate externalsecret talosconfig force-sync="$(date +%s)" --overwrite
kubectl -n etcd-backup create job --from=cronjob/etcd-backup etcd-backup-manual-$(date +%s)
kubectl -n etcd-backup logs -l job-name --tail=50   # expect a snapshot uploaded to S3
```

## Dev ripple
This resource is `count = var.enable_irsa ? 1 : 0`, so Dev (enable_irsa=true) will
ALSO start writing its talosconfig on next Dev apply — overwriting Dev's current
value with the TF-generated one (same CA/certs from state → valid). Expected/benign,
but note it so Dev's next deploy plan showing `+1 create` isn't a surprise.

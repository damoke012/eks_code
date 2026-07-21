# INFRA-1623 / INFRA-1589 item D — make Terraform write the real talosconfig

**Problem:** `modules/irsa/talosconfig-secret.tf` creates the SM secret **wrapper only**.
Its comment says the value is "provisioned out-of-band", and the import file's placeholder
literal is `PLACEHOLDER_POPULATED_BY_TERRAFORM_ON_FIRST_APPLY` — the intent was always for
TF to populate it, but no `aws_secretsmanager_secret_version` was ever written.

**Impact:** SM `op-usxpress-qa/talosconfig` = `PLACEHOLDER_POPULATE`. ESO syncs it green.
The `etcd-snapshot-to-s3` CronJob mounts it at `/etc/talos/config` and `talosctl` dies:
`cannot unmarshal !!str "PLACEHO..." into config.Config`. **QA has had zero etcd snapshots
for 13+ days**, and prod would inherit the same defect.

**The material already exists:** `main.tf:1` declares `talos_machine_secrets.cluster`, and
`.client_configuration` is already consumed at `main.tf:165`.

---

## Patch

### 1. Generate the talosconfig document — `deploy/terraform/main.tf`

The talos provider's `talos_client_configuration` data source renders a ready-to-use
talosconfig YAML from the machine secrets:

```hcl
data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.cluster.client_configuration
  endpoints            = [var.cluster_vip]        # e.g. 10.10.82.51 for QA
  nodes                = var.control_plane_ips    # reuse whatever main.tf already builds
}
```
Reuse the existing variables/locals for VIP and CP IPs rather than introducing new ones —
they already exist (they're surfaced as the `control_plane_ips` output).

### 2. Write the value — `modules/irsa/talosconfig-secret.tf`

Add a variable and the version resource alongside the existing wrapper, gated on the same
flag the grafana value-writes use:

```hcl
variable "talosconfig_value" {
  description = "Rendered talosconfig YAML. Written to the SM secret when manage_platform_secret_values is true."
  type        = string
  sensitive   = true
  default     = null
}

resource "aws_secretsmanager_secret_version" "talosconfig" {
  count         = var.manage_platform_secret_values && var.talosconfig_value != null ? 1 : 0
  secret_id     = aws_secretsmanager_secret.talosconfig.id
  secret_string = var.talosconfig_value
}
```

**No `ignore_changes` here** — unlike the grafana azure-ad secret (where a human injects the
real Entra value and TF must not clobber it), the talosconfig is fully TF-derived and TF
should own it outright. That's what makes a from-scratch rebuild self-healing.

### 3. Pass it in — wherever `module "irsa"` is instantiated

```hcl
module "irsa" {
  # ...existing args...
  talosconfig_value = data.talos_client_configuration.this.talos_config
}
```

---

## Deploy + verify

```bash
# via Octopus (routine path — never local apply)
octopus release create --project "iaac-talos" --space "DevOps" --channel feature --no-prompt
octopus release deploy --project "iaac-talos" --space "DevOps" --version <v> --environment qa --no-prompt

# 1. SM no longer a placeholder (prints the YAML header, not PLACEHOLDER_*)
aws secretsmanager get-secret-value --profile usx-qa \
  --secret-id op-usxpress-qa/talosconfig --query SecretString --output text | head -c 20; echo

# 2. force ESO to pick it up (refreshInterval is 1h)
export KUBECONFIG=~/.kube/op-usxpress-qa.yaml
kubectl cluster-info | head -1        # MUST be 10.10.82.51, not .50 (dev)
kubectl -n etcd-backup annotate externalsecret talosconfig force-sync=$(date +%s) --overwrite
kubectl -n etcd-backup get secret talosconfig -o jsonpath='{.data.config}' | base64 -d | head -c 20; echo

# 3. prove the job works
kubectl -n etcd-backup create job --from=cronjob/etcd-snapshot-to-s3 verify-$(date +%s)
kubectl -n etcd-backup get jobs         # expect Complete, not Failed
aws s3 ls s3://etcd-snapshots-op-usxpress-qa --profile usx-qa | tail -5
```

Note the secret key is **`config`**, not `talosconfig` — that's what the ExternalSecret
maps and what the pod mounts. No remapping needed.

## Then: prove the rebuild

The REBUILD-RUNBOOK's prereq is "once the value-writes change is deployed". With this
landed, run the QA teardown + rebuild for real. Until that's exercised end-to-end, the
"100% IaC, zero manual" property is asserted, not demonstrated — and prod would be built
on an unvalidated path.

#!/usr/bin/env bash
# ==============================================================================
# Full-teardown-clean: TF writes the platform secret VALUES + makes the SM
# wrappers immediately recreatable, so a complete destroy+apply self-seeds.
# INFRA-1589. Run from ~/work/iaac-talos on refactor/multi-env-parameterization.
# Edits only — review git diff, then commit/push (see the runbook).
# ==============================================================================
set -euo pipefail
cd ~/work/iaac-talos
echo "branch: $(git rev-parse --abbrev-ref HEAD)"
TF=deploy/terraform

# 1) Add hashicorp/random provider (for the grafana admin password)
if ! grep -q 'hashicorp/random' "$TF/providers.tf"; then
  sed -i '/required_providers {/a\    random = {\n      source  = "hashicorp/random"\n      version = "~> 3.6"\n    }' "$TF/providers.tf"
fi

# 2) Root value-writes file (talosconfig real value + grafana admin random +
#    azure-ad placeholder), gated on var.manage_platform_secret_values.
cat > "$TF/secrets-values.tf" <<'EOF'
# secrets-values.tf  (ROOT)  — INFRA-1589 full-teardown-clean
# Writes the platform secret VALUES so a full destroy+apply self-seeds. Gated on
# var.manage_platform_secret_values (QA=true) so the SHARED modules/irsa never
# clobbers Dev/Prod live values. Azure-AD real creds remain the one external step.
locals {
  seed_secret_values = var.enable_irsa && var.manage_platform_secret_values
}

data "talos_client_configuration" "talosconfig" {
  count                = local.seed_secret_values ? 1 : 0
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.cluster.client_configuration
  endpoints            = module.vsphere_cp.ip_addresses
  nodes                = module.vsphere_cp.ip_addresses
}

resource "aws_secretsmanager_secret_version" "talosconfig" {
  count         = local.seed_secret_values ? 1 : 0
  secret_id     = module.irsa[0].talosconfig_secret_arn
  secret_string = data.talos_client_configuration.talosconfig[0].talos_config
}

resource "random_password" "grafana_admin" {
  count            = local.seed_secret_values && var.grafana_admin_secret_arn != "" ? 1 : 0
  length           = 28
  special          = true
  override_special = "!#$%*-_=+"
  keepers          = { cluster = var.cluster_name }
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  count     = local.seed_secret_values && var.grafana_admin_secret_arn != "" ? 1 : 0
  secret_id = module.irsa[0].grafana_admin_secret_arn
  secret_string = jsonencode({
    username = "admin"
    password = random_password.grafana_admin[0].result
  })
}

resource "aws_secretsmanager_secret_version" "grafana_azure_ad" {
  count     = local.seed_secret_values && var.grafana_azure_ad_secret_arn != "" ? 1 : 0
  secret_id = module.irsa[0].grafana_azure_ad_secret_arn
  secret_string = jsonencode({
    client_id     = "PLACEHOLDER"
    client_secret = "PLACEHOLDER"
  })
  lifecycle {
    ignore_changes = [secret_string]
  }
}
EOF

# 3) The QA opt-in flag
if ! grep -q 'manage_platform_secret_values' "$TF/variables.tf"; then
cat >> "$TF/variables.tf" <<'EOF'

variable "manage_platform_secret_values" {
  description = "When true, TF writes the platform secret VALUES (talosconfig, grafana admin pw, grafana azure-ad placeholder) so a full destroy+recreate self-seeds. Default false so shared-module envs (Dev/Prod) keep their out-of-band values until they opt in."
  type        = bool
  default     = false
}
EOF
fi

# 4) QA opts in
if ! grep -q 'manage_platform_secret_values' "$TF/envs/qa.tfvars"; then
cat >> "$TF/envs/qa.tfvars" <<'EOF'

# Full-teardown-clean: TF seeds the platform secret values on apply (INFRA-1589)
manage_platform_secret_values = true
EOF
fi

# 5) Make the reproducible SM wrappers immediately recreatable (no 7-day block on
#    destroy+recreate). These are all TF-reproducible so 0 is safe.
sed -i 's/recovery_window_in_days = 7/recovery_window_in_days = 0/' \
  "$TF/modules/irsa/grafana-secret.tf" "$TF/modules/irsa/talosconfig-secret.tf"

echo; echo "=== DONE. Review: ==="; git diff --stat
echo "Then: terraform fmt && terraform validate  (init needed for the new random provider)"

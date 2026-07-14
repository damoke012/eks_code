#!/usr/bin/env bash
# ==============================================================================
# Codify the grafana SM secrets into modules/irsa + fix the enable_irsa landmine
# in qa.tfvars. INFRA-1589 (make QA rebuild-clean). Edits only — review git diff,
# then commit/push + add Octopus TF_VARs + plan (see APPLY-irsa-grafana.md).
#
# Run from ~/work/iaac-talos on branch refactor/multi-env-parameterization.
# ==============================================================================
set -euo pipefail
cd ~/work/iaac-talos
echo "branch: $(git rev-parse --abbrev-ref HEAD)   (expect refactor/multi-env-parameterization)"
TF=deploy/terraform

# 1) Module: grafana SM secret wrappers — count-gated on the per-env ARN, so an
#    env that hasn't set the ARN gets count=0 (no-op) => safe for the shared module.
cat > "$TF/modules/irsa/grafana-secret.tf" <<'EOF'
# grafana-secret.tf
# SM secret WRAPPERS for Grafana (admin creds + Azure-AD SSO), mirroring
# talosconfig-secret.tf: Terraform owns the wrapper (name/tags/recovery window);
# the VALUE is seeded out-of-band and persists in AWS SM across cluster rebuilds.
# ESO reads them at ${cluster_name}/platform/grafana[/azure-ad] for the
# grafana/grafana-admin and grafana/grafana-azure-ad-creds ExternalSecrets.
#
# count-gated on the per-env ARN input: an env that hasn't set the ARN yet gets
# count=0 (no-op), so adding this to the shared module never breaks a deploy.
# When the ARN is set, the wrapper is managed + adopted via the root import block.
resource "aws_secretsmanager_secret" "grafana_admin" {
  count       = var.grafana_admin_secret_arn != "" ? 1 : 0
  name        = "${var.cluster_name}/platform/grafana"
  description = "Grafana admin credentials (username/password) for ${var.cluster_name}. Consumed by grafana/grafana-admin ExternalSecret. Value seeded out-of-band (self-owned); persists across rebuilds."

  recovery_window_in_days = 7

  tags = {
    Cluster = var.cluster_name
    Purpose = "grafana-admin"
    Owner   = "on-prem-platform"
  }
}

resource "aws_secretsmanager_secret" "grafana_azure_ad" {
  count       = var.grafana_azure_ad_secret_arn != "" ? 1 : 0
  name        = "${var.cluster_name}/platform/grafana/azure-ad"
  description = "Grafana Azure-AD SSO app-registration creds (client_id/client_secret) for ${var.cluster_name}. Consumed by grafana/grafana-azure-ad-creds ExternalSecret. Value seeded out-of-band from the Entra app registration."

  recovery_window_in_days = 7

  tags = {
    Cluster = var.cluster_name
    Purpose = "grafana-azure-ad"
    Owner   = "on-prem-platform"
  }
}

output "grafana_admin_secret_arn" {
  description = "ARN of the grafana-admin SM secret (empty if unmanaged in this env)"
  value       = one(aws_secretsmanager_secret.grafana_admin[*].arn)
}
output "grafana_azure_ad_secret_arn" {
  description = "ARN of the grafana Azure-AD SM secret (empty if unmanaged in this env)"
  value       = one(aws_secretsmanager_secret.grafana_azure_ad[*].arn)
}
EOF

# 2) Module inputs for the ARNs
cat >> "$TF/modules/irsa/variables.tf" <<'EOF'

variable "grafana_admin_secret_arn" {
  description = "ARN of pre-existing grafana-admin SM secret to adopt (empty = unmanaged in this env)."
  type        = string
  default     = ""
}
variable "grafana_azure_ad_secret_arn" {
  description = "ARN of pre-existing grafana Azure-AD SM secret to adopt (empty = unmanaged in this env)."
  type        = string
  default     = ""
}
EOF

# 3) Pass the ARNs into the module call (insert after the tf_state_bucket line)
sed -i '/^  tf_state_bucket  = var.tf_state_bucket$/a\  grafana_admin_secret_arn    = var.grafana_admin_secret_arn\n  grafana_azure_ad_secret_arn = var.grafana_azure_ad_secret_arn' "$TF/main.tf"

# 4) Root vars
cat >> "$TF/variables.tf" <<'EOF'

# --- Parameterized grafana SM secret ARNs (adopt existing wrappers via import) ---
variable "grafana_admin_secret_arn" {
  description = "ARN of the grafana-admin SM secret (<cluster>/platform/grafana) to adopt. Empty = unmanaged."
  type        = string
  default     = ""
}
variable "grafana_azure_ad_secret_arn" {
  description = "ARN of the grafana Azure-AD SM secret (<cluster>/platform/grafana/azure-ad) to adopt. Empty = unmanaged."
  type        = string
  default     = ""
}
EOF

# 5) Root import blocks (mirror talosconfig-secret-import.tf)
cat > "$TF/grafana-secret-import.tf" <<'EOF'
# Adopts the pre-existing grafana SM secrets (seeded out-of-band 2026-07-14)
# into module.irsa so TF manages the wrappers without recreating them. Mirrors
# talosconfig-secret-import.tf. Gated on enable_irsa + the per-env ARN var; an
# empty ARN => no import AND the count-gated resource is absent => clean no-op.
import {
  for_each = var.enable_irsa && var.grafana_admin_secret_arn != "" ? { "wrapper" = true } : {}
  to       = module.irsa[0].aws_secretsmanager_secret.grafana_admin[0]
  id       = var.grafana_admin_secret_arn
}
import {
  for_each = var.enable_irsa && var.grafana_azure_ad_secret_arn != "" ? { "wrapper" = true } : {}
  to       = module.irsa[0].aws_secretsmanager_secret.grafana_azure_ad[0]
  id       = var.grafana_azure_ad_secret_arn
}
EOF

# 6) qa.tfvars: fix the enable_irsa landmine + real talosconfig ARN + grafana ARNs
sed -i \
  -e 's/^enable_irsa[[:space:]]*=.*/enable_irsa           = true/' \
  -e 's#^irsa_oidc_bucket_name[[:space:]]*=.*#irsa_oidc_bucket_name = "op-usxpress-qa-irsa-oidc-v2"#' \
  -e 's#op-usxpress-qa/talosconfig-XXXXXX#op-usxpress-qa/talosconfig-1Q1ozc#' \
  "$TF/envs/qa.tfvars"
cat >> "$TF/envs/qa.tfvars" <<'EOF'

# Grafana platform SM secret ARNs — adopt existing wrappers into module.irsa (INFRA-1589)
grafana_admin_secret_arn    = "arn:aws:secretsmanager:us-east-2:527101283767:secret:op-usxpress-qa/platform/grafana-FMI2a9"
grafana_azure_ad_secret_arn = "arn:aws:secretsmanager:us-east-2:527101283767:secret:op-usxpress-qa/platform/grafana/azure-ad-8PBQhR"
EOF

# 7) dev.tfvars: Dev grafana ARNs (shared-module change must not break Dev's next apply)
cat >> "$TF/envs/dev.tfvars" <<'EOF'

# Grafana platform SM secret ARNs — adopt existing wrappers into module.irsa (INFRA-1589)
grafana_admin_secret_arn    = "arn:aws:secretsmanager:us-east-2:700736442855:secret:op-usxpress-dev/platform/grafana-9O868z"
grafana_azure_ad_secret_arn = "arn:aws:secretsmanager:us-east-2:700736442855:secret:op-usxpress-dev/platform/grafana/azure-ad-Y9xkdl"
EOF

echo
echo "=== DONE editing. Review before committing: ==="
git diff --stat
echo
echo "Next: terraform fmt + validate, then the plan (see APPLY-irsa-grafana.md)."

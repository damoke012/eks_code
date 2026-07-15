# secrets-values.tf  (ROOT module)  — INFRA-1589 full-teardown-clean
#
# Writes the platform secret VALUES so a full `terraform destroy` + apply
# re-seeds itself with ZERO manual steps (except the one external Azure-AD
# app-registration secret, which by definition can't live in git/TF).
#
# Gated on var.manage_platform_secret_values (QA = true). Default false so the
# SHARED modules/irsa doesn't clobber Dev/Prod's live grafana admin / azure-ad
# values — those envs opt in later when they're made rebuild-clean too.
#
# Makes automatic on a from-scratch recreate:
#   talosconfig    -> real value from the cluster's machine secrets (etcd-backup works)
#   grafana admin  -> fresh strong random password (retrieve from SM after apply)
#   grafana azuread-> PLACEHOLDER so grafana BOOTS; real Entra creds are injected
#                     out-of-band and preserved across applies by ignore_changes.

locals {
  seed_secret_values = var.enable_irsa && var.manage_platform_secret_values
}

# --- talosconfig: real value from the cluster's machine secrets (item D) ------
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

# --- grafana admin: auto-generated strong password ----------------------------
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

# --- grafana azure-ad: placeholder so grafana boots; real Entra creds persist --
resource "aws_secretsmanager_secret_version" "grafana_azure_ad" {
  count     = local.seed_secret_values && var.grafana_azure_ad_secret_arn != "" ? 1 : 0
  secret_id = module.irsa[0].grafana_azure_ad_secret_arn
  secret_string = jsonencode({
    client_id     = "PLACEHOLDER"
    client_secret = "PLACEHOLDER"
  })
  lifecycle {
    ignore_changes = [secret_string] # real Entra creds seeded out-of-band survive applies
  }
}

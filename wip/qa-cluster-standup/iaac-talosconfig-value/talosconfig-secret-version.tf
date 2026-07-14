# talosconfig-secret-version.tf  (ROOT module)  — INFRA-1589 item D
#
# Writes the REAL talosconfig VALUE into the ${cluster}/talosconfig SM secret so
# the etcd-backup ExternalSecret syncs a working config instead of the literal
# PLACEHOLDER_POPULATED_BY_TERRAFORM_ON_FIRST_APPLY (which it never was — no
# secret_version existed). This closes the last "rebuild-clean" gap: on every
# apply TF regenerates the talosconfig from the cluster's machine secrets and
# stores it, so a destroy+recreate produces a working etcd-backup with zero
# manual seeding. Matches the checklist DR principle "TF manages talosconfig".
#
# Root-scoped because it needs BOTH talos_machine_secrets.cluster (root) and the
# SM secret wrapper (module.irsa[0], created only when enable_irsa=true).
#
# Endpoints/nodes = the CP node IPs (talosctl etcd snapshot targets a CP running
# etcd). module.vsphere_cp.ip_addresses is the same source main.tf feeds to
# control_plane_ips.

data "talos_client_configuration" "talosconfig" {
  count                = var.enable_irsa ? 1 : 0
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.cluster.client_configuration
  endpoints            = module.vsphere_cp.ip_addresses
  nodes                = module.vsphere_cp.ip_addresses
}

resource "aws_secretsmanager_secret_version" "talosconfig" {
  count         = var.enable_irsa ? 1 : 0
  secret_id     = module.irsa[0].talosconfig_secret_arn
  secret_string = data.talos_client_configuration.talosconfig[0].talos_config

  # The wrapper already exists (imported); this just writes the current value.
  depends_on = [module.irsa]
}

# op-usxpress-qa environment values.
# New cluster; three-pool worker architecture per QA delta doc.
#
# Secrets (vsphere_password, github_token) still come from Octopus
# environment-scoped variables — NOT in this file.

cluster_name              = "op-usxpress-qa"

# Control plane — bigger than Dev to safely host security agents (Wiz etc.)
control_plane_count       = 3
cp_cpus                   = 4
cp_memory_mb              = 16384     # 16 GB — up from Dev's 8 GB per delta doc

# Workers — three-pool architecture
worker_pools = {
  system = {
    count        = 2
    cpus         = 4
    memory_mb    = 8192
    disk_size_gb = 100
    ceph_disk_gb = 0
    labels       = { pool = "system" }
    taints       = []
  }
  platform = {
    count        = 3
    cpus         = 8
    memory_mb    = 16384
    disk_size_gb = 200
    ceph_disk_gb = 0
    labels       = { pool = "platform" }
    taints       = ["pool=platform:NoSchedule"]
  }
  application = {
    count        = 5
    cpus         = 16
    memory_mb    = 32768
    disk_size_gb = 300
    ceph_disk_gb = 500
    labels       = { pool = "application" }
    taints       = ["pool=application:NoSchedule"]
  }
}

# Legacy scalars unused when worker_pools is populated, but must be set
# (Terraform still requires values for declared variables). Set to zero-ish.
worker_count              = 0
worker_cpus               = 4
worker_memory_mb          = 8192
disk_size_gb              = 100
worker_ceph_disk_gb       = 0

# Env-gated modules
enable_rw2_imports        = false     # RW-2 not going to QA in Phase 1

# Talosconfig SM secret ARN — MUST be seeded before first apply
# (talosctl generates a talosconfig; then aws secretsmanager create-secret
#  --name op-usxpress-qa/talosconfig ...; then paste the full ARN below)
talosconfig_secret_arn    = "arn:aws:secretsmanager:us-east-2:527101283767:secret:op-usxpress-qa/talosconfig-XXXXXX"

# Cluster identity — TBD from vSphere/network allocation
control_plane_vip         = "TBD-qa-vip"
endpoint                  = "https://TBD-qa-vip:6443"
talos_version             = "1.11.1"
control_plane_name_prefix = "talos-cp-op-qa"
worker_name_prefix        = "talos-wk-op-qa"

# vSphere placement — TBD from Octopus QA env vars
# datacenter                = "..."
# datastore                 = "..."
# vm_cluster_name           = "..."
# vm_folder                 = "usxpress/op-usxpress-qa"
# network_name              = "..."
# content_library_name      = "..."
# content_library_item_name = "..."

# Cilium (same as Dev)
cilium_chart_version      = "1.18.2"
cilium_cli_image          = "quay.io/cilium/cilium-cli:v0.18.7"

# IRSA — start OFF; enable in Phase 2 once cloud team drops ONPREM_BOOTSTRAP_ROLE_ARN_QA
enable_irsa               = false
aws_region                = "us-east-2"
irsa_oidc_bucket_name     = ""        # populate when enable_irsa flipped true
irsa_role_arn             = ""

# Flux — new op-qa branch of iaac-talos-flux-platform (needs to exist before Flux bootstrap)
github_owner              = "variant-inc"
github_repository         = "iaac-talos-flux-platform"
github_branch             = "op-qa"
flux_target_path          = "clusters/op-usxpress-qa"

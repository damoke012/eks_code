# op-usxpress-dev environment values.
# Migrates existing Dev config to the parameterized envs/*.tfvars pattern.
# Retains flat-worker layout — worker_pools left empty so main.tf's fallback
# uses the legacy scalars, matching current Dev cluster exactly.
#
# Secrets (vsphere_password, github_token) still come from Octopus
# environment-scoped variables — NOT in this file.

cluster_name              = "op-usxpress-dev"

# Control plane
control_plane_count       = 3
cp_cpus                   = 4
cp_memory_mb              = 8192      # NOTE: Dev on 8 GB. QA is 16 GB.

# Workers — flat single-pool (worker_pools empty → main.tf fallback path)
worker_pools              = {}
worker_count              = 7
worker_cpus               = 4
worker_memory_mb          = 12288
disk_size_gb              = 50
worker_ceph_disk_gb       = 50

# Env-gated modules
enable_rw2_imports        = true      # Dev is the only env with RW-2 (op-usxpress-dev/risingwave-2 IRSA + S3 buckets)

# Talosconfig SM secret ARN (seeded out-of-band 2026-06-23)
talosconfig_secret_arn    = "arn:aws:secretsmanager:us-east-2:700736442855:secret:op-usxpress-dev/talosconfig-jZx93J"

# Cluster identity
control_plane_vip         = "10.10.82.50"
endpoint                  = "https://10.10.82.50:6443"
talos_version             = "1.11.1"
control_plane_name_prefix = "talos-cp-op-dev"
worker_name_prefix        = "talos-wk-op-dev"

# vSphere placement (fill from Octopus Dev env vars — TBD in this file)
# datacenter                = "..."
# datastore                 = "..."
# vm_cluster_name           = "..."
# vm_folder                 = "..."
# network_name              = "..."
# content_library_name      = "..."
# content_library_item_name = "..."

# Cilium (matches current)
cilium_chart_version      = "1.18.2"
cilium_cli_image          = "quay.io/cilium/cilium-cli:v0.18.7"

# IRSA
enable_irsa               = true
aws_region                = "us-east-2"
irsa_oidc_bucket_name     = "op-usxpress-dev-irsa-oidc"
irsa_role_arn             = ""        # empty = no cross-account assume; TF runs directly in USX-Dev

# Flux
github_owner              = "variant-inc"
github_repository         = "iaac-talos-flux-platform"
github_branch             = "op-dev"
flux_target_path          = "clusters/op-usxpress-dev"

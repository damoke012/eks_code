# Additions to deploy/terraform/variables.tf.
# Append this block at the end of variables.tf.
# Existing scalar variables (worker_count, worker_cpus, etc.) stay in place
# as a fallback for envs that haven't migrated to worker_pools yet.

# --- Worker pool architecture (new; used by QA + future Prod) -------------

variable "worker_pools" {
  description = <<-EOT
    Per-pool worker sizing + labels + taints. Empty map falls back to legacy
    scalar variables (worker_count / worker_cpus / worker_memory_mb /
    disk_size_gb / worker_ceph_disk_gb) — that path keeps Dev working
    unchanged during the refactor.

    Example (QA):
      worker_pools = {
        system      = { count = 2, cpus = 4,  memory_mb = 8192,  disk_size_gb = 100, ceph_disk_gb = 0,   labels = { pool = "system" },      taints = [] }
        platform    = { count = 3, cpus = 8,  memory_mb = 16384, disk_size_gb = 200, ceph_disk_gb = 0,   labels = { pool = "platform" },    taints = ["pool=platform:NoSchedule"] }
        application = { count = 5, cpus = 16, memory_mb = 32768, disk_size_gb = 300, ceph_disk_gb = 500, labels = { pool = "application" }, taints = ["pool=application:NoSchedule"] }
      }
  EOT
  type = map(object({
    count        = number
    cpus         = number
    memory_mb    = number
    disk_size_gb = number
    ceph_disk_gb = number
    labels       = map(string)
    taints       = list(string)
  }))
  default = {}
}

# --- Env-gated optional modules (RW-2 imports currently Dev-only) --------

variable "enable_rw2_imports" {
  description = "Enable RisingWave-2 S3/IAM imports (currently Dev-only). Set false for QA/Prod until RW-2 is provisioned there."
  type        = bool
  default     = false
}

# --- Parameterized talosconfig SM secret ARN -----------------------------

variable "talosconfig_secret_arn" {
  description = "Full ARN of the talosconfig secret in the target account's SM. Per-env — must be seeded out-of-band per-cluster before apply."
  type        = string
}

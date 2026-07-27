# op-usxpress-prod environment values.  DRAFT — INFRA-1589 / INFRA-1621.
#
# Built 2026-07-24 by modelling on the verified op-usxpress-qa tfvars.
# QA is a deliberate Prod-standard mirror, so QA's shape is the correct
# starting point for prod; sizing may go UP but not down.
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ THREE CLASSES OF VALUE IN THIS FILE — do not confuse them:               │
# │  1. RESOLVED   — known and written in.                                   │
# │  2. MIRRORED   — copied from QA; CONFIRM prod isn't meant to differ.     │
# │  3. TBD-PROD-* — genuinely unknown. Left as a sentinel that BREAKS a     │
# │                  plan loudly rather than resolving to a wrong value.     │
# │                  This is the INFRA-1623 lesson: a wrong value that       │
# │                  deploys clean is worse than a value that fails init.    │
# └─────────────────────────────────────────────────────────────────────────┘
#
# Secrets (vsphere_password, github_token) come from Octopus environment-scoped
# variables, NOT this file.  Deploy is Octopus-only — never local `terraform apply`.

cluster_name              = "op-usxpress-prod"   # RESOLVED

# ── Control plane ────────────────────────────────────────────────────────────
# MIRRORED from QA. Prod likely wants >=3 CPs at QA's size or larger. CONFIRM.
control_plane_count       = 3
cp_cpus                   = 4
cp_memory_mb              = 16384
control_plane_name_prefix = "talos-cp-op-prod"

# ── Workers — three-pool architecture (MIRRORED from QA) ─────────────────────
# CONFIRM prod sizing with the capacity plan. "QA mirrors prod" means these
# numbers were chosen AS prod's shape, so treat changes as deliberate, not free.
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

# Legacy scalars — unused when worker_pools is populated, but must be set.
worker_count              = 0
worker_cpus               = 4
worker_memory_mb          = 8192
disk_size_gb              = 100
worker_ceph_disk_gb       = 0
worker_name_prefix        = "talos-wk-op-prod"

# ── Env-gated modules ────────────────────────────────────────────────────────
enable_rw2_imports        = false     # RW-2 is dev-only; never goes to prod.

# ── Cluster identity — VIP SELF-ASSIGNED on vLAN 82, same as dev/qa ──────────
# dev=.50, qa=.51, prod=.52. Verified free 2026-07-24 (silent to ping, no
# kubeconfig references it). Networking is NOTIFIED of the reservation, not
# asked to allocate — matches how dev/qa were built. Node IPs are DHCP on the
# vLAN (like QA's scattered .25/.24/.177 CPs), so there is NO per-node IP list.
control_plane_vip         = "10.10.82.52"                   # RESOLVED
endpoint                  = "https://10.10.82.52:6443"
talos_version             = "1.11.1"                        # MIRRORED — confirm target

# ── AWS — VERIFIED 2026-07-24 via sts get-caller-identity ────────────────────
# op-dev→700736442855, op-qa→527101283767, op-prod→937464026810 (ops-controller
# / usxpress-prod). Account is CONFIRMED, not inferred — validate-register.sh
# ran get-caller-identity on all three profiles, prod returned 937464026810.
aws_region                = "us-east-2"                     # RESOLVED

# State backend — per-account. Prod account has two candidate buckets:
#   lazy-tf-state-ipp58n854uhpw13x   ← matches QA's lazy-tf-state-* scheme (likely)
#   usxpress-tf-state-25cypfeqq8xpf582
# CONFIRM which holds iaac/talos state (s3 ls .../iaac/talos/), then set below.
# (Set via Octopus TF_VAR/backend flags, mirrored here for local plan only.)
# tf_state_bucket         = "lazy-tf-state-ipp58n854uhpw13x"   # CONFIRM
# TF_STATE_KEY            = "iaac/talos/op-usxpress-prod.tfstate"

# ── DNS — RESOLVED 2026-07-24 via Route53 in the prod account ────────────────
# Public hosted zone usxpress-prod.com exists in 937464026810. That's the prod
# domain: external-dns --domain-filter=usxpress-prod.com, ingress hosts under it,
# --txt-owner-id=op-usxpress-prod (NOT op-usxpress-dev — that's the QA bug).

# Talosconfig SM secret — created DURING the build (talosctl gen → aws sm
# create-secret --name op-usxpress-prod/talosconfig). ARN not known until then.
talosconfig_secret_arn    = "arn:aws:secretsmanager:us-east-2:937464026810:secret:op-usxpress-prod/talosconfig-TBD"

# ── vSphere placement — prod-DESIGNATED infra (RESOLVED 2026-07-24) ──────────
# The names say PROD: datastore USXD1NTXPROD-SC1, network "vLAN 82 Prod". These
# are prod's own storage/network — QA is co-tenanting on them, not the reverse.
# So prod belongs here; dedicated vm_folder gives clean inventory separation.
# datacenter / vm_cluster_name are UNSCOPED (global) Octopus vars shared across
# envs — QA didn't env-scope them and neither do we.
# ⚠️ PRE-APPLY GATE: verify USXD1NTXPROD-SC1 has headroom for prod's ~5 TB ON TOP
#    of QA's current usage. See RUNBOOK §pre-apply. Capacity is the one thing
#    co-tenancy makes NOT automatically true.
datastore                 = "USXD1NTXPROD-SC1"
vm_folder                 = "/KubernetesD1/TalosD1/op-usxpress-prod"
network_name              = "10.10.82 (vLAN 82) Prod"
content_library_name      = "dev-cluster"
content_library_item_name = "talos-v1.11.1"

# ── Cilium (MIRRORED — same across all on-prem clusters) ─────────────────────
cilium_chart_version      = "1.18.2"
cilium_cli_image          = "quay.io/cilium/cilium-cli:v0.18.7"

# ── IRSA ─────────────────────────────────────────────────────────────────────
# LANDMINE (E5 / STATE.md): never commit enable_irsa=false once the IRSA
# resources exist in state — a false flips them to DESTROY on the next apply.
# For a fresh prod build the resources don't exist yet, so the first apply may
# run with false; flip to true once cloud drops ONPREM_BOOTSTRAP_ROLE_ARN_PROD
# and the OIDC bucket exists. After that, NEVER set it back to false.
enable_irsa               = false     # flip true in phase 2, then leave it
irsa_oidc_bucket_name     = ""        # TBD-PROD — populate when enable_irsa=true
irsa_role_arn             = ""        # TBD-PROD — from cloud team

# ── Flux — new op-prod branch (must exist before Flux bootstrap) ─────────────
github_owner              = "variant-inc"
github_repository         = "iaac-talos-flux-platform"
github_branch             = "op-prod"
flux_target_path          = "clusters/op-usxpress-prod"

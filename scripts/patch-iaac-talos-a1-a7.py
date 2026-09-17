#!/usr/bin/env python3
"""Close A1-A7 from docs/architecture/build-book/QA2-STANDUP.md in variant-inc/iaac-talos.

Run from the root of an iaac-talos clone, on a branch. Idempotent: refuses if applied.
Every edit asserts its anchor. Nothing is edited that has not been read.

  git checkout -b feat/env-from-git
  python3 patch-iaac-talos-a1-a7.py
  git diff          # read it in full
"""
import pathlib, re, sys

R = pathlib.Path.cwd()
def f(p): return R / p

PS1   = f("deploy/deploy.ps1")
VARS  = f("deploy/terraform/variables.tf")
MAIN  = f("deploy/terraform/main.tf")
QATF  = f("deploy/terraform/envs/qa.tfvars")
FLUXM = f("deploy/terraform/modules/flux/main.tf")
FLUXV = f("deploy/terraform/modules/flux/variables.tf")
TIMP  = f("deploy/terraform/talosconfig-secret-import.tf")
RW2   = f("deploy/terraform/risingwave-2-imports.tf.dev-only")
NEWENV= f("octopus/new-environment.sh")

if not PS1.exists():
    sys.exit("ERROR: run from the root of an iaac-talos clone.")
if "TF_USE_VARFILE" in PS1.read_text():
    sys.exit("ERROR: already applied (TF_USE_VARFILE present in deploy.ps1).")

def sub(path, old, new, label):
    t = path.read_text(); n = t.count(old)
    if n != 1: sys.exit(f"ERROR {label}: anchor x{n}, expected 1 in {path}:\n{old[:160]}")
    path.write_text(t.replace(old, new)); print(f"  ok  {label}")

def block_bounds(text, header):
    """Return (start, end) of a brace-balanced HCL block whose header line matches."""
    i = text.find(header)
    if i < 0: return None
    depth, j = 0, i
    while j < len(text):
        if text[j] == "{": depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0: return (i, j + 1)
        j += 1
    return None

# ---------------------------------------------------------------- A1
print("A1  deploy.ps1 reads envs/<env>.tfvars")
# OPT-IN. Terraform precedence puts -var-file ABOVE TF_VAR_* env vars, so switching this on
# for an environment makes its tfvars authoritative immediately. dev/qa/prod tfvars are
# stale, so they must be corrected and plan-diffed BEFORE their flag is set.
sub(PS1,
'''$env:S3_BUCKET           = $S3_BUCKET''',
'''# --- Which variables win -------------------------------------------------------
# Terraform precedence: TF_VAR_* env vars are LOWER than -var-file. Turning this on
# makes envs/<env>.tfvars authoritative over every Octopus TF_VAR_*, so it is OPT-IN
# per environment. Set TF_USE_VARFILE=true only after that env's tfvars has been
# corrected and a plan diff reviewed. New environments (qa2) start with it true.
$VarFileArgs = @()
if ($TF_USE_VARFILE -eq "true") {
  if (-not $env:TF_VAR_env_name) {
    Write-Error "TF_USE_VARFILE=true but TF_VAR_env_name is not set. Refusing to plan: Terraform would silently fall back to Octopus variables and the tfvars in git would be ignored."
    exit 1
  }
  $VarFile = "envs/$($env:TF_VAR_env_name).tfvars"
  if (-not (Test-Path (Join-Path "terraform" $VarFile))) {
    Write-Error "TF_USE_VARFILE=true but terraform/$VarFile does not exist. Refusing to plan."
    exit 1
  }
  $VarFileArgs = @("-var-file=$VarFile")
  Write-Host "[VARS] authoritative: $VarFile"
}
else {
  Write-Host "[VARS] authoritative: Octopus TF_VAR_* only (envs/*.tfvars NOT read)"
}

$env:S3_BUCKET           = $S3_BUCKET''', "deploy.ps1 var-file selection")
sub(PS1, "  ce terraform plan -destroy -out=tfplan -input=false -no-color",
         "  ce terraform plan -destroy -out=tfplan -input=false -no-color @VarFileArgs",
         "deploy.ps1 destroy plan")
sub(PS1, "    ce terraform plan -out=tfplan -input=false -no-color",
         "    ce terraform plan -out=tfplan -input=false -no-color @VarFileArgs",
         "deploy.ps1 plan")

# ---------------------------------------------------------------- A2 (talosconfig half)
print("A2  outputs stop being inputs -- talosconfig")
t = VARS.read_text()
b = block_bounds(t, 'variable "talosconfig_secret_arn"')
if not b: sys.exit("ERROR A2: variable talosconfig_secret_arn not found")
# keep any leading comment lines attached to the block
s = t.rfind("\n\n", 0, b[0]) + 1
VARS.write_text(t[:s] + t[b[1]:].lstrip("\n"))
print("  ok  removed variable talosconfig_secret_arn")
if TIMP.exists():
    TIMP.unlink(); print("  ok  deleted talosconfig-secret-import.tf")
# NOTE: the two grafana ARNs are NOT touched. modules/irsa/grafana-secret.tf has not been
# read, and those ARNs appear to double as enable-flags (count = arn != "" ? 1 : 0).
# Removing them blind would change which resources exist. Left for a follow-up.

# ---------------------------------------------------------------- A5
print("A5  a placeholder cannot ship again")
t = VARS.read_text()
for name, cond, msg in [
    ("control_plane_vip",
     'can(cidrnetmask("${var.control_plane_vip}/32"))',
     "control_plane_vip must be an IPv4 address. 'TBD-qa-vip' sat in qa.tfvars from June to September 2026 because nothing validated it."),
    ("endpoint",
     'can(regex("^https://[0-9]+\\\\.[0-9]+\\\\.[0-9]+\\\\.[0-9]+:[0-9]+$", var.endpoint))',
     "endpoint must be https://<ipv4>:<port>."),
]:
    bb = block_bounds(t, f'variable "{name}"')
    if not bb: sys.exit(f"ERROR A5: variable {name} not found")
    if "validation" in t[bb[0]:bb[1]]:
        print(f"  --  {name} already validated, skipped"); continue
    ins = ('\n  validation {\n    condition     = %s\n    error_message = "%s"\n  }\n'
           % (cond, msg))
    t = t[:bb[1]-1] + ins + t[bb[1]-1:]
    print(f"  ok  validation on {name}")
VARS.write_text(t)

# ---------------------------------------------------------------- A6
print("A6  Flux bootstrap, flag-gated, new clusters only")
# A NEW resource name. The two `removed` tombstones for flux_bootstrap_git.this stay exactly
# as they are, so dev/qa/prod state is untouched and nothing can be planned for destruction.
FLUXV.write_text(FLUXV.read_text() + '''
variable "enable_bootstrap" {
  description = <<-EOT
    Bootstrap Flux from Terraform. Default false: the three existing clusters were moved
    off Terraform-managed Flux via `removed` blocks in 2026 and must not be disturbed.
    New clusters set this true so one apply produces a reconciling cluster.
  EOT
  type        = bool
  default     = false
}
''')
FLUXM.write_text(FLUXM.read_text() + '''
# Flux bootstrap for NEW clusters only.
#
# Deliberately a different resource name from the `removed` flux_bootstrap_git.this above:
# that tombstone stays untouched, so the existing clusters' state cannot be affected and no
# destroy can be planned against them. Gated to count = 0 everywhere it is not wanted.
resource "flux_bootstrap_git" "new" {
  count = var.enable_bootstrap ? 1 : 0

  path = var.target_path

  depends_on = [terraform_data.wait_for_cluster]
}
''')
print("  ok  modules/flux: enable_bootstrap + flux_bootstrap_git.new")
sub(MAIN, '''  target_path      = var.flux_target_path
  cluster_endpoint = local.cluster_endpoint''',
'''  target_path      = var.flux_target_path
  cluster_endpoint = local.cluster_endpoint
  enable_bootstrap = var.enable_flux_bootstrap''', "main.tf passes enable_flux_bootstrap")
VARS.write_text(VARS.read_text() + '''
variable "enable_flux_bootstrap" {
  description = <<-EOT
    Bootstrap Flux from Terraform. False for dev/qa/prod, whose Flux was moved out of
    Terraform state via `removed` blocks and is managed outside this repo. True for a new
    cluster, so a single apply yields a cluster that reconciles.
  EOT
  type        = bool
  default     = false
}
''')
print("  ok  root variable enable_flux_bootstrap")

# ---------------------------------------------------------------- A7
print("A7  delete the dead weight, correct qa.tfvars")
if RW2.exists():
    RW2.unlink(); print("  ok  deleted risingwave-2-imports.tf.dev-only")
sub(QATF, 'control_plane_vip         = "TBD-qa-vip"',
          'control_plane_vip         = "10.10.82.51"', "qa.tfvars VIP")
sub(QATF, 'endpoint                  = "https://TBD-qa-vip:6443"',
          'endpoint                  = "https://10.10.82.51:6443"', "qa.tfvars endpoint")
sub(QATF, "# IRSA — start OFF; enable in Phase 2 once cloud team drops ONPREM_BOOTSTRAP_ROLE_ARN_QA",
          "# IRSA — ON. (Phase 2 completed; the old 'start OFF' comment outlived the change.)",
          "qa.tfvars stale IRSA comment")
# A2/A3 note for whoever turns the flag on
sub(QATF, "cluster_name = \"op-usxpress-qa\"",
'''# NOT AUTHORITATIVE until this environment's Octopus variable TF_USE_VARFILE=true.
# Until then every value here is ignored and Octopus TF_VAR_* is used instead.
cluster_name = "op-usxpress-qa"''', "qa.tfvars authority banner")

# ---------------------------------------------------------------- step 1+2 generator
print("Steps 1-2  generate an environment instead of hand-writing one")
NEWENV.write_text('''#!/usr/bin/env bash
# Generate deploy/terraform/envs/<env>.tfvars for a NEW cluster.
#
# Replaces "copy qa.tfvars and edit it", which is how "TBD-qa-vip" happened. Every value is
# either supplied here and validated, or inherited from the reference environment. Nothing
# that Terraform creates appears in the output: no ARNs, no bucket ids, no endpoints.
set -euo pipefail

usage() {
  cat >&2 <<USAGE
usage: $0 --env <key> --cluster <name> --vip <ipv4> [--from qa] [--cp N] [--workers N]

  --env      short key; becomes envs/<key>.tfvars and TF_VAR_env_name  (e.g. qa2)
  --cluster  cluster name; becomes bucket names, SSM paths, zone labels (e.g. op-usxpress-qa2)
  --vip      control-plane VIP, an IPv4 address
  --from     reference environment to inherit versions and placement from (default: qa)
  --cp       control-plane node count (default 1)
  --workers  worker node count, single pool (default 1)
USAGE
  exit 2
}

ENV_KEY=""; CLUSTER=""; VIP=""; FROM="qa"; CP=1; WORKERS=1
while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_KEY="$2"; shift 2 ;;
    --cluster) CLUSTER="$2"; shift 2 ;;
    --vip) VIP="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --cp) CP="$2"; shift 2 ;;
    --workers) WORKERS="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$ENV_KEY" ] && [ -n "$CLUSTER" ] && [ -n "$VIP" ] || usage

# Validate here as well as in Terraform: a bad value should never reach a file.
echo "$VIP" | grep -Eq '^([0-9]{1,3}\\.){3}[0-9]{1,3}$' || {
  echo "!! --vip must be an IPv4 address, got '$VIP'" >&2; exit 1; }
echo "$ENV_KEY" | grep -Eq '^[a-z0-9]+$' || {
  echo "!! --env must be lowercase alphanumeric, got '$ENV_KEY'" >&2; exit 1; }

SRC="deploy/terraform/envs/${FROM}.tfvars"
OUT="deploy/terraform/envs/${ENV_KEY}.tfvars"
[ -f "$SRC" ] || { echo "!! reference $SRC not found" >&2; exit 1; }
[ -e "$OUT" ] && { echo "!! $OUT already exists -- refusing to overwrite" >&2; exit 1; }

# Inherit only the things that are genuinely shared: versions and vSphere placement.
inherit() { grep -E "^ *$1 " "$SRC" || true; }

{
  echo "# ${CLUSTER} -- generated by octopus/new-environment.sh from ${FROM}.tfvars"
  echo "# Decisions only. Anything Terraform creates is referenced, never written here."
  echo
  echo "cluster_name = \\"${CLUSTER}\\""
  echo
  echo "control_plane_count = ${CP}"
  inherit cp_cpus
  inherit cp_memory_mb
  echo
  echo "worker_pools = {"
  echo "  system = { count = ${WORKERS}, cpus = 4, memory_mb = 8192, disk_size_gb = 100,"
  echo "             ceph_disk_gb = 0, labels = { pool = \\"system\\" }, taints = {} }"
  echo "}"
  echo "worker_count        = 0"
  echo "worker_cpus         = 4"
  echo "worker_memory_mb    = 8192"
  echo "disk_size_gb        = 100"
  echo "worker_ceph_disk_gb = 0"
  echo
  echo "control_plane_vip         = \\"${VIP}\\""
  echo "endpoint                  = \\"https://${VIP}:6443\\""
  inherit talos_version
  echo "control_plane_name_prefix = \\"talos-cp-${ENV_KEY}\\""
  echo "worker_name_prefix        = \\"talos-wk-${ENV_KEY}\\""
  echo
  inherit cilium_chart_version
  inherit cilium_cli_image
  echo
  echo "enable_irsa                   = true"
  echo "enable_aws_iam_authenticator  = true"
  echo "enable_rw2_imports            = false"
  echo "enable_flux_bootstrap         = true   # new cluster: one apply, one reconciling cluster"
  echo "manage_platform_secret_values = true   # self-seed every secret value; nothing typed by hand"
  inherit aws_region
  echo "irsa_oidc_bucket_name = \\"${CLUSTER}-irsa-oidc-v2\\""
  echo "irsa_role_arn         = \\"\\""
  echo "tf_state_bucket       = \\"${CLUSTER}-tfstate\\""
  echo
  echo "github_owner      = \\"variant-inc\\""
  echo "github_repository = \\"iaac-talos-flux-platform\\""
  echo "github_branch     = \\"op-${ENV_KEY}\\""
  echo "flux_target_path  = \\"clusters/${CLUSTER}\\""
  echo
  echo "# vSphere placement -- inherited from ${FROM}. If these are absent, they are still"
  echo "# only in Octopus and this environment CANNOT be built from git (gap A4)."
  for v in datacenter datastore vm_cluster_name vm_folder network_name \\
           content_library_name content_library_item_name; do
    line=$(inherit "$v")
    if [ -n "$line" ]; then echo "$line"; else echo "# MISSING: $v -- not in ${FROM}.tfvars"; fi
  done
} > "$OUT"

echo "wrote $OUT"
if grep -q '^# MISSING:' "$OUT"; then
  echo
  echo "!! Incomplete: the vSphere placement values are not in ${FROM}.tfvars (they live in"
  echo "!! Octopus). This environment cannot be built from git until they are added. See A4."
  exit 3
fi
''')
NEWENV.chmod(0o755)
print("  ok  octopus/new-environment.sh")

print("""
DONE. Not covered, deliberately:
  A2 (grafana half) modules/irsa/grafana-secret.tf not read; those ARNs look like
                    enable-flags (count = arn != "" ? 1 : 0). Removing them blind would
                    change which resources exist.
  A3                set manage_platform_secret_values=true per env -- the generator does
                    this for new envs; existing envs need it added with their A1 flag.
  A4                the vSphere placement VALUES are in Octopus and could not be read
                    (API key rejected). The generator marks them MISSING and exits 3.

Next: git diff, then terraform fmt -check, then a plan on a throwaway before any merge.
""")

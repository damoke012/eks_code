#!/usr/bin/env bash
#
# octopus/new-environment.sh -- create deploy/terraform/envs/<env>.tfvars for a NEW cluster.
#
# Replaces "copy qa.tfvars and edit it", which is how "TBD-qa-vip" reached a committed file
# and sat there unnoticed because nothing read it. Every value here is either supplied on the
# command line, typed at a prompt, or inherited from a reference environment -- and every one
# of them is validated before it is written. A placeholder cannot be saved.
#
# Nothing Terraform CREATES appears in the output: no role ARNs, no OIDC bucket ids, no
# endpoints that Terraform derives. Only decisions.
#
# Run from the repo root:  ./octopus/new-environment.sh
#
set -euo pipefail

# ---------------------------------------------------------------- output helpers

die()   { printf '\n!! %s\n\n' "$*" >&2; exit 1; }
note()  { printf '   %s\n' "$*" >&2; }
warn()  { printf '\n ** %s\n' "$*" >&2; }
title() { printf '\n== %s\n' "$*" >&2; }

INTERACTIVE=1
[ -t 0 ] || INTERACTIVE=0

# ---------------------------------------------------------------- validators
#
# Each returns 0 for a value that may be written, 1 for one that may not. They are
# deliberately stricter than Terraform: a bad value should never reach a file, because a file
# is what gets reviewed, copied and inherited by the next environment.

PLACEHOLDER_RE='TBD|TODO|CHANGE.?ME|PLACEHOLDER|FIXME|^XXX|^<|>$|\.\.\.|^your-|^some-'

is_placeholder() {
  [ -z "$1" ] && return 0
  printf '%s' "$1" | grep -Eqi "$PLACEHOLDER_RE"
}

v_envkey()  { printf '%s' "$1" | grep -Eq '^[a-z][a-z0-9-]{1,15}$'; }
v_cluster() { printf '%s' "$1" | grep -Eq '^[a-z][a-z0-9-]{2,40}$'; }
v_posint()  { printf '%s' "$1" | grep -Eq '^[0-9]{1,6}$' && [ "$1" -ge 1 ]; }
v_int0()    { printf '%s' "$1" | grep -Eq '^[0-9]{1,6}$'; }
v_abspath() { printf '%s' "$1" | grep -Eq '^/[^ ]+$'; }
v_region()  { printf '%s' "$1" | grep -Eq '^[a-z]{2}-[a-z]+-[0-9]$'; }
v_semver()  { printf '%s' "$1" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+'; }
v_any()     { [ -n "$1" ]; }

v_ipv4() {
  local ip="$1" o
  printf '%s' "$ip" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || return 1
  local IFS=.
  # shellcheck disable=SC2086
  set -- $ip
  for o in "$@"; do
    [ "$o" -le 255 ] || return 1
  done
  return 0
}

# ---------------------------------------------------------------- ask
#
# ask VAR "question" validator "default" "hint"
#
# If VAR already holds a value (from a flag) it is validated and kept -- a bad flag is an
# error, never a silent prompt. With no terminal, a missing value with no default is fatal:
# this script must be safe to call from CI without it inventing anything.

ask() {
  local __var=$1 question=$2 validator=$3 default=${4-} hint=${5-}
  local cur=${!__var-} reply

  if [ -n "$cur" ]; then
    is_placeholder "$cur" && die "$__var: '$cur' looks like a placeholder. $hint"
    "$validator" "$cur"   || die "$__var: '$cur' is not valid. $hint"
    return 0
  fi

  if [ "$INTERACTIVE" -eq 0 ]; then
    [ -n "$default" ] || die "$__var has no value and there is no terminal to ask at. $hint"
    is_placeholder "$default" && die "$__var: inherited default '$default' is a placeholder. $hint"
    printf -v "$__var" '%s' "$default"
    return 0
  fi

  while :; do
    if [ -n "$default" ]; then
      read -r -p "   ${question} [${default}]: " reply || die "aborted"
      [ -z "$reply" ] && reply=$default
    else
      read -r -p "   ${question}: " reply || die "aborted"
    fi
    if is_placeholder "$reply"; then
      note "that is a placeholder, not a value -- this is exactly what the script exists to stop"
      continue
    fi
    if "$validator" "$reply"; then
      printf -v "$__var" '%s' "$reply"
      return 0
    fi
    note "not valid. ${hint}"
  done
}

confirm() {
  local question=$1 reply
  [ "${ACCEPT_ALL:-0}" = "1" ] && { note "$question -- accepted by --yes"; return 0; }
  if [ "$INTERACTIVE" -eq 0 ]; then
    die "$question -- rerun with --yes to accept non-interactively"
  fi
  read -r -p "   ${question} [type yes]: " reply || die "aborted"
  [ "$reply" = "yes" ] || die "declined"
}

# ---------------------------------------------------------------- arguments

usage() {
  cat >&2 <<'USAGE'
usage: octopus/new-environment.sh [--env KEY] [--cluster NAME] [--vip IPv4] [--from ENV] [...]

  Run it with no arguments and it asks for everything it needs.
  Every flag below simply pre-answers one of those questions.

  --env KEY         short key; becomes envs/<KEY>.tfvars and TF_VAR_env_name   e.g. qa2
  --cluster NAME    cluster name; drives bucket names, SSM paths, IAM scope    e.g. op-usxpress-qa-2
  --vip IPv4        control-plane VIP                                          e.g. 10.10.82.53
  --from ENV        reference environment to inherit from (default: qa)
  --cp N            control-plane node count
  --workers N       worker node count (single 'system' pool)
  --yes             accept warnings non-interactively (CI)
  -h, --help        this
USAGE
  exit 2
}

ENV_KEY=""; CLUSTER=""; VIP=""; FROM="qa"; CP_COUNT=""; WORKER_COUNT=""; ACCEPT_ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --env)     ENV_KEY=${2-};      shift 2 ;;
    --cluster) CLUSTER=${2-};      shift 2 ;;
    --vip)     VIP=${2-};          shift 2 ;;
    --from)    FROM=${2-};         shift 2 ;;
    --cp)      CP_COUNT=${2-};     shift 2 ;;
    --workers) WORKER_COUNT=${2-}; shift 2 ;;
    --yes)     ACCEPT_ALL=1;       shift ;;
    -h|--help) usage ;;
    *) printf '!! unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

# --yes means "do not ask me anything": take every default, fail on anything with no default.
# Without this, a prompt in a terminal happily reads whatever is left in the paste buffer.
[ "$ACCEPT_ALL" = "1" ] && INTERACTIVE=0

ENVS_DIR="deploy/terraform/envs"
[ -d "$ENVS_DIR" ] || die "run this from the repo root -- $ENVS_DIR does not exist here"

SRC="${ENVS_DIR}/${FROM}.tfvars"
[ -f "$SRC" ] || die "reference environment '$FROM' not found at $SRC"

# inherit FIELD -> the bare value of a "field = \"value\"" or "field = 123" line, or empty
inherit() {
  sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"?([^\"#]*[^\"# ])\"?.*/\1/p" "$SRC" | head -1
}

# ---------------------------------------------------------------- what already exists
#
# Read every environment already defined, so the new one can be checked against all of them
# rather than against the single file it was copied from.

declare -a KNOWN_CLUSTERS=() KNOWN_VIPS=() KNOWN_FILES=()
for f in "$ENVS_DIR"/*.tfvars; do
  [ -e "$f" ] || continue
  c=$(sed -nE 's/^[[:space:]]*cluster_name[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p'      "$f" | head -1)
  v=$(sed -nE 's/^[[:space:]]*control_plane_vip[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$f" | head -1)
  [ -n "$c" ] && { KNOWN_CLUSTERS+=("$c"); KNOWN_VIPS+=("${v:-none}"); KNOWN_FILES+=("$f"); }
done

title "Existing environments in this repo"
if [ ${#KNOWN_CLUSTERS[@]} -eq 0 ]; then
  note "(none found -- this is the first)"
else
  for i in "${!KNOWN_CLUSTERS[@]}"; do
    printf '   %-24s %-16s %s\n' "${KNOWN_CLUSTERS[$i]}" "${KNOWN_VIPS[$i]}" "${KNOWN_FILES[$i]}" >&2
  done
fi

# ---------------------------------------------------------------- the decisions

title "The new environment"

ask ENV_KEY "environment key (becomes envs/<key>.tfvars and TF_VAR_env_name)" \
    v_envkey "" "lowercase letters, digits and hyphens, 2-16 characters"

OUT="${ENVS_DIR}/${ENV_KEY}.tfvars"
[ -e "$OUT" ] && die "$OUT already exists -- delete it or choose another key. This script never overwrites."

ask CLUSTER "cluster name (drives bucket names, SSM paths and the IAM scope)" \
    v_cluster "op-usxpress-${ENV_KEY}" "lowercase letters, digits and hyphens, 3-41 characters"

for c in "${KNOWN_CLUSTERS[@]}"; do
  [ "$c" = "$CLUSTER" ] && die "cluster_name '$CLUSTER' is already used by another environment"
done

# The IAM check. Terraform's bootstrap policy is scoped to "<cluster>-*", and
# apply-bootstrap-perms.sh REPLACES that inline policy rather than adding to it. So a second
# cluster in an account that already has one is safe ONLY if its name extends an existing
# cluster name at a hyphen: op-usxpress-qa-2 falls inside op-usxpress-qa-*, and needs no IAM
# change at all. op-usxpress-qa2 does NOT -- it needs its own grant, and writing that grant
# de-authorises op-usxpress-qa.
IAM_INHERITED_FROM=""
for c in "${KNOWN_CLUSTERS[@]}"; do
  case "$CLUSTER" in
    "$c"-*)
      IAM_INHERITED_FROM=$c ;;
    "$c"*)
      warn "IAM: '$CLUSTER' starts with '$c' but NOT at a hyphen."
      note "The existing grant is scoped '${c}-*', which does not match '${CLUSTER}-*'."
      note "This cluster needs its own IAM policy, and apply-bootstrap-perms.sh REPLACES the"
      note "inline policy -- writing it would de-authorise ${c}."
      note "Naming it '${c}-${CLUSTER#"$c"}' instead makes the whole problem disappear."
      confirm "Continue with a name that needs separate IAM?" ;;
  esac
done
[ -n "$IAM_INHERITED_FROM" ] && \
  note "IAM: inside ${IAM_INHERITED_FROM}-* -- no bootstrap IAM change needed for this cluster."

ask VIP "control-plane VIP (IPv4, must be free and routable from the workers)" \
    v_ipv4 "" "four dotted octets, each 0-255"

for i in "${!KNOWN_VIPS[@]}"; do
  [ "${KNOWN_VIPS[$i]}" = "$VIP" ] && \
    die "VIP $VIP is already the control-plane VIP of ${KNOWN_CLUSTERS[$i]}. Two clusters cannot share one."
done

# A VIP outside the subnet every other cluster uses is usually a typo, occasionally correct.
REF_VIP=$(inherit control_plane_vip)
if [ -n "$REF_VIP" ] && [ "${VIP%.*}" != "${REF_VIP%.*}" ]; then
  warn "VIP $VIP is not in ${REF_VIP%.*}.0/24, where ${FROM} lives."
  confirm "Is that deliberate?"
fi

# ---------------------------------------------------------------- sizing

title "Machine sizes -- control plane"
ask CP_COUNT  "control-plane node count"          v_posint "$(inherit control_plane_count)" "a whole number, 1 or more (use 3 for HA)"
ask CP_CPUS   "control-plane vCPUs per node"      v_posint "$(inherit cp_cpus)"             "a whole number of vCPUs"
ask CP_MEM    "control-plane memory per node, MB" v_posint "$(inherit cp_memory_mb)"        "megabytes, e.g. 8192"

title "Machine sizes -- workers (one 'system' pool; add more by editing the file after)"
ask WORKER_COUNT "worker node count"            v_posint "1"    "a whole number, 1 or more"
ask WORKER_CPUS  "worker vCPUs per node"        v_posint "4"    "a whole number of vCPUs"
ask WORKER_MEM   "worker memory per node, MB"   v_posint "8192" "megabytes, e.g. 16384"
ask WORKER_DISK  "worker root disk, GB"         v_posint "100"  "gigabytes"
ask WORKER_CEPH  "worker Ceph data disk, GB (0 for none)" v_int0 "0" "gigabytes, or 0"

# ---------------------------------------------------------------- versions and region

title "Versions and region (inherited from ${FROM} -- change only with a reason)"
ask TALOS_VERSION  "Talos version"        v_semver "$(inherit talos_version)"        "e.g. v1.8.3"
ask CILIUM_VERSION "Cilium chart version" v_any    "$(inherit cilium_chart_version)" "a chart version"
ask CILIUM_CLI     "Cilium CLI image"     v_any    "$(inherit cilium_cli_image)"     "a full image reference"
ask AWS_REGION     "AWS region"           v_region "$(inherit aws_region)"           "e.g. us-east-2"

# The state bucket is per AWS ACCOUNT, with TF_STATE_KEY separating clusters inside it. A new
# cluster in an existing account REUSES the bucket; only a new account needs a new one.
ask TF_STATE_BUCKET "Terraform state bucket (reuse the account's own -- new only for a new AWS account)" \
    v_any "$(inherit tf_state_bucket)" "an S3 bucket name that already exists, or one to create"

# ---------------------------------------------------------------- vSphere placement
#
# These seven were absent from git until 2026-09-17 and lived only in Octopus, which is why an
# environment could not be rebuilt from the repo alone. They are inherited here, but every one
# is still shown and confirmable, because a new cluster is exactly when a folder or a network
# legitimately differs.

title "vSphere placement (inherited from ${FROM})"
ask VS_DATACENTER  "datacenter"            v_any     "$(inherit datacenter)"                 "the vSphere datacenter name"
ask VS_DATASTORE   "datastore"             v_any     "$(inherit datastore)"                  "the datastore name"
ask VS_VMCLUSTER   "vm_cluster_name"       v_any     "$(inherit vm_cluster_name)"            "the compute cluster name"
ask VS_NETWORK     "network_name"          v_any     "$(inherit network_name)"               "the port group name"
ask VS_LIBRARY     "content_library_name"  v_any     "$(inherit content_library_name)"       "the content library holding the Talos OVA"
ask VS_LIBITEM     "content_library_item_name" v_any "$(inherit content_library_item_name)"  "the OVA item name"

REF_FOLDER=$(inherit vm_folder)
REF_CLUSTER=$(sed -nE 's/^[[:space:]]*cluster_name[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$SRC" | head -1)
DEFAULT_FOLDER="${REF_FOLDER:-/KubernetesD1/TalosD1/${CLUSTER}}"
[ -n "$REF_FOLDER" ] && [ -n "$REF_CLUSTER" ] && DEFAULT_FOLDER="${REF_FOLDER//${REF_CLUSTER}/${CLUSTER}}"
ask VS_FOLDER "vm_folder (its own folder -- never shared with another cluster)" \
    v_abspath "$DEFAULT_FOLDER" "an absolute vSphere inventory path"

for i in "${!KNOWN_FILES[@]}"; do
  other=$(sed -nE 's/^[[:space:]]*vm_folder[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "${KNOWN_FILES[$i]}" | head -1)
  [ -n "$other" ] && [ "$other" = "$VS_FOLDER" ] && \
    die "vm_folder $VS_FOLDER already belongs to ${KNOWN_CLUSTERS[$i]}. A destroy would take both clusters' VMs."
done

# ---------------------------------------------------------------- review, then write

title "Review"
cat >&2 <<REVIEW
   environment key     ${ENV_KEY}          -> ${OUT}
   cluster             ${CLUSTER}
   control-plane VIP   ${VIP}              -> endpoint https://${VIP}:6443
   control plane       ${CP_COUNT} x ${CP_CPUS} vCPU / ${CP_MEM} MB
   workers             ${WORKER_COUNT} x ${WORKER_CPUS} vCPU / ${WORKER_MEM} MB / ${WORKER_DISK} GB (+${WORKER_CEPH} GB Ceph)
   Talos               ${TALOS_VERSION}
   AWS region          ${AWS_REGION}
   state bucket        ${TF_STATE_BUCKET}
   vSphere folder      ${VS_FOLDER}
REVIEW
confirm "Write this file?"

# VM name prefixes follow the FLEET convention, derived from the cluster name rather than the
# environment key: op-usxpress-qa -> talos-cp-op-qa, matching dev and prod. Deriving them from
# the env key would give talos-cp-qa2, which no other cluster looks like -- and the Octopus
# variable for this cluster already says talos-cp-op-qa-2.
case "$CLUSTER" in
  op-usxpress-*) NAME_SHORT="op-${CLUSTER#op-usxpress-}" ;;
  *)             NAME_SHORT="$ENV_KEY" ;;
esac

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

{
  echo "# ${CLUSTER} -- generated by octopus/new-environment.sh from ${FROM}.tfvars"
  echo "# Decisions only. Anything Terraform creates is referenced, never written here."
  echo "# Read only when TF_USE_VARFILE=true; otherwise Octopus TF_VAR_* still win."
  echo
  echo "cluster_name = \"${CLUSTER}\""
  echo
  echo "control_plane_count = ${CP_COUNT}"
  echo "cp_cpus             = ${CP_CPUS}"
  echo "cp_memory_mb        = ${CP_MEM}"
  echo
  echo "worker_pools = {"
  echo "  system = { count = ${WORKER_COUNT}, cpus = ${WORKER_CPUS}, memory_mb = ${WORKER_MEM}, disk_size_gb = ${WORKER_DISK},"
  echo "             ceph_disk_gb = ${WORKER_CEPH}, labels = { pool = \"system\" }, taints = {} }"
  echo "}"
  echo "# Legacy scalars: ignored whenever worker_pools is non-empty (local.effective_worker_pools)."
  echo "worker_count        = 0"
  echo "worker_cpus         = ${WORKER_CPUS}"
  echo "worker_memory_mb    = ${WORKER_MEM}"
  echo "disk_size_gb        = ${WORKER_DISK}"
  echo "worker_ceph_disk_gb = ${WORKER_CEPH}"
  echo
  echo "control_plane_vip         = \"${VIP}\""
  echo "endpoint                  = \"https://${VIP}:6443\""
  echo "talos_version             = \"${TALOS_VERSION}\""
  echo "control_plane_name_prefix = \"talos-cp-${NAME_SHORT}\""
  echo "worker_name_prefix        = \"talos-wk-${NAME_SHORT}\""
  echo
  echo "cilium_chart_version = \"${CILIUM_VERSION}\""
  echo "cilium_cli_image     = \"${CILIUM_CLI}\""
  echo
  echo "enable_irsa                   = true"
  echo "enable_aws_iam_authenticator  = true"
  echo "enable_rw2_imports            = false"
  echo "enable_flux_bootstrap         = true   # new cluster: one apply, one reconciling cluster"
  echo "manage_platform_secret_values = true   # self-seed every secret value; nothing typed by hand"
  echo "aws_region            = \"${AWS_REGION}\""
  echo "irsa_oidc_bucket_name = \"${CLUSTER}-irsa-oidc-v2\""
  echo "irsa_role_arn         = \"\""
  echo "tf_state_bucket       = \"${TF_STATE_BUCKET}\""
  echo
  echo "# Flux bootstrap targets the CLUSTER repo on master, into clusters/<name>/ --"
  echo "# not the platform repo on a branch. Confirmed against live Octopus 2026-09-17."
  echo "github_owner      = \"variant-inc\""
  echo "github_repository = \"iaac-talos-flux-cluster\""
  echo "github_branch     = \"master\""
  echo "flux_target_path  = \"clusters/${CLUSTER}\""
  echo
  echo "# vSphere placement"
  echo "datacenter                = \"${VS_DATACENTER}\""
  echo "datastore                 = \"${VS_DATASTORE}\""
  echo "vm_cluster_name           = \"${VS_VMCLUSTER}\""
  echo "network_name              = \"${VS_NETWORK}\""
  echo "content_library_name      = \"${VS_LIBRARY}\""
  echo "content_library_item_name = \"${VS_LIBITEM}\""
  echo "vm_folder                 = \"${VS_FOLDER}\""
} > "$TMP"

# Nothing unresolved may reach the repo.
if grep -Eqi "$PLACEHOLDER_RE" "$TMP"; then
  warn "the generated file still contains an unresolved value -- refusing to write it:"
  grep -Eni "$PLACEHOLDER_RE" "$TMP" >&2
  exit 3
fi

mkdir -p "$ENVS_DIR"
cp "$TMP" "$OUT"
printf '\nwrote %s\n' "$OUT"

# ---------------------------------------------------------------- what is still human

cat >&2 <<NEXT

Still to do, in order. None of it is in this file.

 1. Octopus environment, worker pool and lifecycle phase
       PR to iaac-octopus-config:
         deploy/config/environments.yaml  append '${ENV_KEY}' (append -- inserting renumbers the rest)
         deploy/config/worker_pools.yaml  append the pool this cluster deploys from
         deploy/config/lifecycles.yaml    add '${ENV_KEY}' to a phase -- an environment in no
                                          phase exists but can never receive a deployment
       Then set SpacesVariablesTfApply=true, or the run only prints a plan.

 2. Octopus project variables on iaac-talos (DevOps space) -- no repo manages these:
         TF_VAR_env_name      ${ENV_KEY}
         TF_USE_VARFILE       true          <- makes THIS file authoritative
         S3_BUCKET            ${TF_STATE_BUCKET}
         TF_STATE_KEY         per convention
         AWS_DEFAULT_REGION   ${AWS_REGION}
         TfApply              false         <- read the plan first
         TfDestroy            false
         TF_VAR_vsphere_password, TF_VAR_github_token   (secrets)

 3. Flux wiring -- BOTH, or the cluster bootstraps into nothing:
         iaac-talos-flux-cluster   PR adding clusters/${CLUSTER}/ on master
         iaac-talos-flux-platform  a branch named by that directory's infra-source.yaml

 4. Before setting TF_USE_VARFILE=true, confirm this environment's state contains
    module.irsa[0].aws_secretsmanager_secret.talosconfig.

NEXT

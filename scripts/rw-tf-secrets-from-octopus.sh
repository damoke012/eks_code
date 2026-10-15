#!/usr/bin/env bash
#
# rw-tf-secrets-from-octopus.sh -- let Terraform write the three THIRD-PARTY
# secrets from Octopus sensitive variables, so a new environment's first apply
# comes up complete with no human step.
#
# Today secrets-app.tf creates kafka, mongodb and dex_entra_client_secret
# holding UNVERIFIED_ sentinels, and a person injects the real values once per
# environment. That is the last manual step between us and "a new environment
# just works".
#
# deploy.ps1 already exports every Octopus variable named TF_* as an
# environment variable ("so Terraform picks up TF_VAR_* automatically"), so an
# Octopus variable called TF_VAR_kafka_values reaches Terraform with NO script
# change. Verified by reading deploy.ps1 on main, 2026-10-15.
#
# Shape: one map(string) per secret, not one variable per key. Adding a key
# later is then a data change in Octopus rather than a code change here.
#
# Behaviour is unchanged when the variables are absent: merge() leaves the
# sentinels in place. Supply the map and the FIRST apply writes the real
# credential; ignore_changes = [secret_string] then stops every later apply
# touching it. That is the whole point -- it is safe precisely because it can
# only ever act once per environment.
#
# After merging, create these in Octopus, SENSITIVE, scoped per environment:
#
#   TF_VAR_kafka_values
#     {"kafka__api_key":"...","kafka__api_secret":"...",
#      "kafka__bootstrap_server":"...","kafka__group_id_prefix":"dx__qa_risingwave",
#      "kafka__schema_registry_api_key":"...","kafka__schema_registry_api_secret":"...",
#      "kafka__schema_registry_endpoint":"..."}
#
#   TF_VAR_mongodb_values
#     {"MONGODB_CONNECTION_STRING":"mongodb+srv://...","MONGODB_USERNAME":"...",
#      "MONGODB_PASSWORD":"..."}
#
#   TF_VAR_dex_values
#     {"DEX_ENTRA_CLIENT_SECRET":"..."}
#
# This writes a branch and shows the diff. It does not push and does not apply.

set -euo pipefail

D=$(mktemp -d)
gh repo clone variant-inc/iaac-risingwave-onprem "$D/repo" -- --depth 1 -q
cd "$D/repo"

python3 - deploy/terraform/secrets-app.tf <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
hits = 0

anchor = 'locals {\n  // Self-describing sentinel'
block = '''// ── Third-party values, supplied per environment from Octopus ──────────────
// deploy.ps1 exports every Octopus variable named TF_* as an environment
// variable, so an Octopus variable called TF_VAR_kafka_values reaches Terraform
// with no script change. Mark them SENSITIVE in Octopus.
//
// A map, not one variable per key: adding a key later is then a data change in
// Octopus rather than a code change here.
//
// Supply nothing and the secret is created holding the UNVERIFIED_ sentinels,
// exactly as before. Supply the map and the FIRST apply writes the real
// credential -- after which ignore_changes means nothing can overwrite it.
variable "kafka_values" {
  description = "Confluent credentials for this environment. Keys override the sentinels."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "mongodb_values" {
  description = "Atlas connection values for this environment. Keys override the sentinels."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "dex_values" {
  description = "Dex/Entra client secret for this environment. Keys override the sentinels."
  type        = map(string)
  default     = {}
  sensitive   = true
}

'''
if anchor in s:
    s = s.replace(anchor, block + anchor, 1); hits += 1

old = '  unset = "UNVERIFIED_SET_THIS_VALUE"\n}'
new = '''  unset = "UNVERIFIED_SET_THIS_VALUE"

  // The SHAPE of each secret, independent of whether its values are known.
  // Read from dev's live ExternalSecrets on 2026-10-15; mongodb carries THREE
  // keys, not one -- the ETL consumes only the connection string, but a new
  // environment must match dev or the other two are silently absent.
  kafka_defaults = {
    kafka__api_key                    = local.unset
    kafka__api_secret                 = local.unset
    kafka__bootstrap_server           = local.unset
    kafka__group_id_prefix            = local.unset
    kafka__schema_registry_api_key    = local.unset
    kafka__schema_registry_api_secret = local.unset
    kafka__schema_registry_endpoint   = local.unset
  }

  mongodb_defaults = {
    MONGODB_CONNECTION_STRING = local.unset
    MONGODB_USERNAME          = local.unset
    MONGODB_PASSWORD          = local.unset
  }

  dex_defaults = {
    DEX_ENTRA_CLIENT_SECRET = local.unset
  }
}'''
if old in s:
    s = s.replace(old, new, 1); hits += 1

old = '''  secret_string = jsonencode({
    kafka__api_key                    = local.unset
    kafka__api_secret                 = local.unset
    kafka__bootstrap_server           = local.unset
    kafka__group_id_prefix            = local.unset
    kafka__schema_registry_api_key    = local.unset
    kafka__schema_registry_api_secret = local.unset
    kafka__schema_registry_endpoint   = local.unset
  })'''
if old in s:
    s = s.replace(old, '  secret_string = jsonencode(merge(local.kafka_defaults, var.kafka_values))', 1); hits += 1

old = '  secret_string = jsonencode({ MONGODB_CONNECTION_STRING = local.unset })'
if old in s:
    s = s.replace(old, '  secret_string = jsonencode(merge(local.mongodb_defaults, var.mongodb_values))', 1); hits += 1

old = '  secret_string = jsonencode({ DEX_ENTRA_CLIENT_SECRET = local.unset })'
if old in s:
    s = s.replace(old, '  secret_string = jsonencode(merge(local.dex_defaults, var.dex_values))', 1); hits += 1

p.write_text(s)
print("edits applied:", hits, "(want 5)")
PY

echo
if command -v terraform >/dev/null 2>&1; then
  terraform -chdir=deploy/terraform init -backend=false -no-color >/dev/null 2>&1 || true
  terraform -chdir=deploy/terraform validate -no-color || echo "VALIDATE FAILED"
else
  echo "terraform absent - not a validation failure"
fi

echo
git checkout -q -b feat/third-party-secrets-from-octopus
git --no-pager diff -- deploy/terraform/secrets-app.tf | cat
echo
echo "Clone: $D/repo"
echo
echo "No import address changes: the resources are the same, only their"
echo "secret_string expression differs."

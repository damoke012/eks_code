#!/usr/bin/env python3
"""
add-qa-vars.py — Add QA-scoped variables to iaac-talos project in Octopus.

Prereq:
  - `octopus login` completed (uses ~/.octopus/cli_config.json for API key)
  - `pip install requests` (or use system requests package)

What it does:
  1. Resolves project + variable set + QA environment IDs
  2. Backs up current variable set to /tmp/octopus-varset-backup-<ts>.json
  3. Prints the QA variables that would be added
  4. Prompts for confirmation
  5. Merges + PUTs the updated variable set

Safety:
  - Only ADDS new QA-scoped entries. Never touches Dev-scoped variables.
  - If a QA-scoped variable with same name already exists, skips it (no dupes).
  - Backup allows revert via a single PUT of the backup file.
"""

import json
import os
import sys
from pathlib import Path

try:
    import requests
except ImportError:
    print("ERROR: requests library missing. Install with: pip install requests", file=sys.stderr)
    sys.exit(1)

# ---- Config -----------------------------------------------------------------

OCTO_URL = "https://octopus.usxpress.io"
SPACE_ID = "Spaces-2"                     # DevOps space
PROJECT_SLUG = "iaac-talos"
QA_ENV_NAME = "qa"

# Locate CLI config for API key — try known locations across CLI versions
CLI_CONFIG_CANDIDATES = [
    Path.home() / ".config" / "octopus" / "cli_config.json",   # CLI 2.x (XDG)
    Path.home() / ".octopus" / "cli_config.json",              # older CLI
]

# ---- QA variables to add ----------------------------------------------------
# Every entry becomes a project variable scoped to Environment=qa.
# Values that already exist as unscoped/global vars don't need to be here — only QA-specific overrides.

QA_VARS = {
    # Cluster identity + state
    "TF_STATE_KEY":                   "iaac/talos/op-usxpress-qa.tfstate",
    "TF_VAR_tf_state_bucket":         "lazy-tf-state-425rbol87rmn6c7m",
    "TF_VAR_cluster_name":            "op-usxpress-qa",
    "TF_VAR_aws_region":              "us-east-2",

    # Control plane
    "TF_VAR_cp_cpus":                 "4",
    "TF_VAR_cp_memory_mb":            "16384",
    "TF_VAR_control_plane_name_prefix": "talos-cp-op-qa",
    "TF_VAR_control_plane_vip":       "10.10.82.51",
    "TF_VAR_endpoint":                "https://10.10.82.51:6443",

    # Workers
    "TF_VAR_worker_count":            "0",
    "TF_VAR_worker_cpus":             "4",
    "TF_VAR_worker_memory_mb":        "8192",
    "TF_VAR_worker_ceph_disk_gb":     "0",
    "TF_VAR_worker_name_prefix":      "talos-wk-op-qa",

    # Storage
    "TF_VAR_disk_size_gb":            "100",

    # vSphere placement
    "TF_VAR_datastore":               "USXD1NTXPROD-SC1",
    "TF_VAR_network_name":            "10.10.82 (vLAN 82) Prod",
    "TF_VAR_vm_folder":               "/KubernetesD1/TalosD1/op-usxpress-qa",
    "TF_VAR_content_library_name":    "dev-cluster",
    "TF_VAR_content_library_item_name": "talos-v#{TF_VAR_talos_version}",
    "TF_VAR_talos_version":           "1.11.1",

    # Talos secret
    "TF_VAR_talosconfig_secret_arn":  "arn:aws:secretsmanager:us-east-2:527101283767:secret:op-usxpress-qa/talosconfig-1Q1ozc",

    # IRSA — MUST be true for QA: the IRSA resources (roles/OIDC/buckets/SM) are
    # already in the QA tfstate. false here would DESTROY them on apply (landmine).
    "TF_VAR_enable_irsa":             "true",
    "TF_VAR_irsa_oidc_bucket_name":   "op-usxpress-qa-irsa-oidc-v2",

    # Flux
    "TF_VAR_flux_target_path":        "clusters/op-usxpress-qa",
}

# Three-pool architecture (JSON as a single-line string)
QA_VARS["TF_VAR_worker_pools"] = json.dumps({
    "system": {
        "count": 2, "cpus": 4, "memory_mb": 8192,
        "disk_size_gb": 100, "ceph_disk_gb": 0,
        "labels": {"pool": "system"},
        "taints": {},
    },
    "platform": {
        "count": 3, "cpus": 8, "memory_mb": 16384,
        "disk_size_gb": 200, "ceph_disk_gb": 0,
        "labels": {"pool": "platform"},
        "taints": {"pool": "platform:NoSchedule"},
    },
    "application": {
        "count": 5, "cpus": 16, "memory_mb": 32768,
        "disk_size_gb": 300, "ceph_disk_gb": 500,
        "labels": {"pool": "application"},
        "taints": {"pool": "application:NoSchedule"},
    },
})

# ---- Auth -------------------------------------------------------------------

def load_api_key():
    config_path = None
    for candidate in CLI_CONFIG_CANDIDATES:
        if candidate.exists():
            config_path = candidate
            break
    if not config_path:
        sys.exit(f"ERROR: Octopus CLI config not found. Tried: {[str(p) for p in CLI_CONFIG_CANDIDATES]}. "
                 "Run `octopus login` first, or set OCTOPUS_API_KEY env var.")
    cfg = json.loads(config_path.read_text())
    # CLI 2.x flat schema: {"url": "...", "apikey": "API-...", "accesstoken": "..."}
    for k in ("apikey", "ApiKey", "apiKey"):
        if k in cfg and cfg[k]:
            return cfg[k]
    # Older nested schema
    hosts = cfg.get("Hosts") or cfg.get("hosts") or {}
    for host_key, host_val in hosts.items():
        if host_key.rstrip("/") == OCTO_URL.rstrip("/"):
            for k in ("ApiKey", "apiKey", "apikey"):
                if k in host_val and host_val[k]:
                    return host_val[k]
    sys.exit(f"ERROR: Could not find API key in {config_path} (schema mismatch?). "
             "Fallback: set OCTOPUS_API_KEY env var.")

api_key = os.environ.get("OCTOPUS_API_KEY") or load_api_key()

session = requests.Session()
session.headers.update({
    "X-Octopus-ApiKey": api_key,
    "Content-Type": "application/json",
    "Accept": "application/json",
})

def api(method, path, **kw):
    url = f"{OCTO_URL}{path}"
    r = session.request(method, url, **kw)
    if not r.ok:
        sys.exit(f"ERROR {r.status_code} on {method} {path}\n{r.text[:500]}")
    return r.json() if r.text else {}

# ---- Discovery --------------------------------------------------------------

project = api("GET", f"/api/{SPACE_ID}/projects/{PROJECT_SLUG}")
project_id = project["Id"]
varset_id = project["VariableSetId"]
print(f"Project:  {project_id}  ({project['Name']})")
print(f"VarSet:   {varset_id}")

envs = api("GET", f"/api/{SPACE_ID}/environments?take=100")["Items"]
qa_env = next((e for e in envs if e["Name"].lower() == QA_ENV_NAME.lower()), None)
if not qa_env:
    sys.exit(f"ERROR: environment '{QA_ENV_NAME}' not found in space {SPACE_ID}")
qa_env_id = qa_env["Id"]
print(f"QA env:   {qa_env_id}")

# ---- Backup -----------------------------------------------------------------

import time
ts = int(time.time())
backup_path = Path(f"/tmp/octopus-varset-backup-{ts}.json")
current = api("GET", f"/api/{SPACE_ID}/variables/{varset_id}")
backup_path.write_text(json.dumps(current, indent=2))
print(f"Backup:   {backup_path}")

existing_qa_names = {
    v["Name"] for v in current["Variables"]
    if qa_env_id in (v.get("Scope") or {}).get("Environment", [])
}

# ---- Build additions --------------------------------------------------------

to_add = []
skipped = []
for name, value in QA_VARS.items():
    if name in existing_qa_names:
        skipped.append(name)
        continue
    to_add.append({
        "Id": "",
        "Name": name,
        "Value": value,
        "Description": "Added by QA stand-up script (INFRA-1585)",
        "Scope": {"Environment": [qa_env_id]},
        "IsEditable": True,
        "IsSensitive": False,
        "Prompt": None,
        "Type": "String",
    })

# ---- Preview + confirm ------------------------------------------------------

print("\n=== Variables to ADD (QA-scoped) ===")
for v in to_add:
    val_preview = v["Value"][:80] + ("..." if len(v["Value"]) > 80 else "")
    print(f"  {v['Name']:38} = {val_preview}")

if skipped:
    print(f"\n=== Skipped (already exist QA-scoped) ===")
    for n in skipped:
        print(f"  {n}")

if not to_add:
    print("\nNothing to add. Exiting cleanly.")
    sys.exit(0)

print(f"\nBackup written to: {backup_path}")
print(f"To revert: PUT the backup file back to /api/{SPACE_ID}/variables/{varset_id}")
print()
resp = input(f"Proceed with adding {len(to_add)} variables? (yes/NO): ").strip().lower()
if resp != "yes":
    print("Aborted. No changes made.")
    sys.exit(0)

# ---- Merge + PUT ------------------------------------------------------------

updated = dict(current)
updated["Variables"] = current["Variables"] + to_add

api("PUT", f"/api/{SPACE_ID}/variables/{varset_id}", data=json.dumps(updated))
print(f"\n✓ Done. Added {len(to_add)} QA-scoped variables to {PROJECT_SLUG}.")
print(f"  Verify in Octopus UI: {OCTO_URL}/app#/{SPACE_ID}/projects/{project_id}/variables")

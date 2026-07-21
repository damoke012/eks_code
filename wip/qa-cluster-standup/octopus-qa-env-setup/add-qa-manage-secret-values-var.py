#!/usr/bin/env python3
"""
add-qa-manage-secret-values-var.py — Add TF_VAR_manage_platform_secret_values=true
to the iaac-talos project in Octopus, QA-scoped ONLY. INFRA-1623.

Why this matters: iaac-talos PR #56 adds
  aws_secretsmanager_secret_version.talosconfig
count-gated on var.manage_platform_secret_values. Without this Octopus variable
the deploy succeeds and does NOTHING — SM keeps returning PLACEHOLDER_POPULATE
and QA's etcd-snapshot-to-s3 CronJob keeps failing. That is the most confusing
possible failure mode, so set this BEFORE deploying #56.

QA-scoped deliberately. Dev's talosconfig was hand-seeded; if dev's
talos_machine_secrets in tfstate ever drifted from the live cluster, letting TF
generate and overwrite it could break dev's working backups. Prove it on QA
first, then opt dev in as a separate, deliberate change.

Modelled on add-qa-grafana-vars.py (same safety rails).

Prereq:
  - `octopus login` done (uses ~/.config/octopus/cli_config.json) OR set OCTOPUS_API_KEY
  - `pip install requests`

Safety: only ADDS one QA-scoped var; skips if already QA-scoped; backs the full
variable set up to /tmp first; prompts before writing.
"""

import json
import os
import sys
import time
from pathlib import Path

try:
    import requests
except ImportError:
    print("ERROR: requests missing. pip install requests", file=sys.stderr)
    sys.exit(1)

OCTO_URL = "https://octopus.usxpress.io"
SPACE_ID = "Spaces-2"          # DevOps space
PROJECT_SLUG = "iaac-talos"
QA_ENV_NAME = "qa"

CLI_CONFIG_CANDIDATES = [
    Path.home() / ".config" / "octopus" / "cli_config.json",
    Path.home() / ".octopus" / "cli_config.json",
]

QA_VARS = {
    "TF_VAR_manage_platform_secret_values": "true",
}
DESCRIPTION = "Let TF write platform SM secret VALUES (talosconfig) — INFRA-1623"


def load_api_key():
    for candidate in CLI_CONFIG_CANDIDATES:
        if candidate.exists():
            cfg = json.loads(candidate.read_text())
            for k in ("apikey", "ApiKey", "apiKey"):
                if cfg.get(k):
                    return cfg[k]
            hosts = cfg.get("Hosts") or cfg.get("hosts") or {}
            for _, hv in hosts.items():
                for k in ("ApiKey", "apiKey", "apikey"):
                    if hv.get(k):
                        return hv[k]
    sys.exit("ERROR: no Octopus API key found. Run `octopus login` or set OCTOPUS_API_KEY.")


api_key = os.environ.get("OCTOPUS_API_KEY") or load_api_key()
session = requests.Session()
session.headers.update({
    "X-Octopus-ApiKey": api_key,
    "Content-Type": "application/json",
    "Accept": "application/json",
})


def api(method, path, **kw):
    r = session.request(method, f"{OCTO_URL}{path}", **kw)
    if not r.ok:
        sys.exit(f"ERROR {r.status_code} on {method} {path}\n{r.text[:500]}")
    return r.json() if r.text else {}


project = api("GET", f"/api/{SPACE_ID}/projects/{PROJECT_SLUG}")
project_id, varset_id = project["Id"], project["VariableSetId"]
print(f"Project: {project_id} ({project['Name']})   VarSet: {varset_id}")

envs = api("GET", f"/api/{SPACE_ID}/environments?take=100")["Items"]
qa_env = next((e for e in envs if e["Name"].lower() == QA_ENV_NAME.lower()), None)
if not qa_env:
    sys.exit(f"ERROR: environment '{QA_ENV_NAME}' not found")
qa_env_id = qa_env["Id"]
print(f"QA env:  {qa_env_id}")

ts = int(time.time())
backup_path = Path(f"/tmp/octopus-varset-backup-{ts}.json")
current = api("GET", f"/api/{SPACE_ID}/variables/{varset_id}")
backup_path.write_text(json.dumps(current, indent=2))
print(f"Backup:  {backup_path}")

# Landmine check — enable_irsa MUST stay true for QA.
for v in current["Variables"]:
    if v["Name"] == "TF_VAR_enable_irsa":
        scope = (v.get("Scope") or {}).get("Environment", [])
        print(f"  [check] TF_VAR_enable_irsa = {v['Value']!r}  scope-env={scope}")

existing_qa = {
    v["Name"] for v in current["Variables"]
    if qa_env_id in (v.get("Scope") or {}).get("Environment", [])
}

to_add = []
for name, value in QA_VARS.items():
    if name in existing_qa:
        print(f"  skip (already QA-scoped): {name}")
        continue
    to_add.append({
        "Id": "", "Name": name, "Value": value,
        "Description": DESCRIPTION,
        "Scope": {"Environment": [qa_env_id]},
        "IsEditable": True, "IsSensitive": False, "Prompt": None, "Type": "String",
    })

if not to_add:
    print("\nNothing to add — already QA-scoped. Exiting.")
    sys.exit(0)

print("\n=== Will ADD (QA-scoped) ===")
for v in to_add:
    print(f"  {v['Name']:40} = {v['Value']}")
print(f"\nRevert: PUT {backup_path} back to /api/{SPACE_ID}/variables/{varset_id}")
if input(f"\nProceed adding {len(to_add)} var(s)? (yes/NO): ").strip().lower() != "yes":
    print("Aborted.")
    sys.exit(0)

updated = dict(current)
updated["Variables"] = current["Variables"] + to_add
api("PUT", f"/api/{SPACE_ID}/variables/{varset_id}", data=json.dumps(updated))
print(f"\n✓ Added {len(to_add)} QA-scoped var(s).")
print(f"  Verify: {OCTO_URL}/app#/{SPACE_ID}/projects/{project_id}/variables")
print("  Then deploy iaac-talos to qa — PR #56's secret_version will now be count=1.")

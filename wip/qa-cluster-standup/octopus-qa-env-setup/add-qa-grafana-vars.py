#!/usr/bin/env python3
"""
add-qa-grafana-vars.py — Add ONLY the 2 grafana SM-secret ARN TF_VARs to the
iaac-talos project in Octopus, QA-scoped. INFRA-1589.

Why a separate focused script (not add-qa-vars.py): this adds exactly two
variables and cannot accidentally touch TF_VAR_enable_irsa (which MUST stay
true for QA — false would destroy the in-state IRSA resources).

These two vars make the Octopus QA apply IMPORT (adopt) the pre-existing grafana
SM secrets via module.irsa. Without them the count-gated wrappers are a safe
no-op; with them, terraform adopts the secrets (plan: 2 import, 0 destroy).

Prereq:
  - `octopus login` done (uses ~/.config/octopus/cli_config.json) OR set OCTOPUS_API_KEY
  - `pip install requests`

Safety: only ADDS the two QA-scoped vars; skips any that already exist QA-scoped;
backs up the full variable set to /tmp first; prompts before writing.
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

# The ONLY two variables this script manages (QA-scoped).
QA_VARS = {
    "TF_VAR_grafana_admin_secret_arn":
        "arn:aws:secretsmanager:us-east-2:527101283767:secret:op-usxpress-qa/platform/grafana-FMI2a9",
    "TF_VAR_grafana_azure_ad_secret_arn":
        "arn:aws:secretsmanager:us-east-2:527101283767:secret:op-usxpress-qa/platform/grafana/azure-ad-8PBQhR",
}


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

# Sanity: report the current enable_irsa value(s) so we can eyeball the landmine.
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
        "Description": "grafana SM secret ARN — adopt via module.irsa import (INFRA-1589)",
        "Scope": {"Environment": [qa_env_id]},
        "IsEditable": True, "IsSensitive": False, "Prompt": None, "Type": "String",
    })

if not to_add:
    print("\nNothing to add. Both grafana vars already QA-scoped. Exiting.")
    sys.exit(0)

print("\n=== Will ADD (QA-scoped) ===")
for v in to_add:
    print(f"  {v['Name']:38} = {v['Value']}")
print(f"\nRevert: PUT {backup_path} back to /api/{SPACE_ID}/variables/{varset_id}")
if input(f"\nProceed adding {len(to_add)} vars? (yes/NO): ").strip().lower() != "yes":
    print("Aborted.")
    sys.exit(0)

updated = dict(current)
updated["Variables"] = current["Variables"] + to_add
api("PUT", f"/api/{SPACE_ID}/variables/{varset_id}", data=json.dumps(updated))
print(f"\n✓ Added {len(to_add)} QA-scoped grafana vars.")
print(f"  Verify: {OCTO_URL}/app#/{SPACE_ID}/projects/{project_id}/variables")

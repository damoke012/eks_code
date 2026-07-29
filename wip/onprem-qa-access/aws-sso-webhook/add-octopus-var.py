#!/usr/bin/env python3
"""
add-octopus-var.py — add ONE environment-scoped variable to the iaac-talos
Octopus project variable set.

Written for TF_VAR_enable_aws_iam_authenticator, but generic. Models
add-prod-vars.py (INFRA-1585/1589) — same auth, same backup-then-PUT shape,
dry-run by default.

WHY THIS EXISTS: Octopus deploys terraform from TF_VAR_* (env.auto.tfvars),
NOT from -var-file, so a value committed to deploy/terraform/envs/qa.tfvars is
never read by a real deploy. The deploy still goes green. See
wip/qa-cluster-standup/APPLY-irsa-grafana.md.

⚠️ AFTER RUNNING THIS: an existing release will NOT pick the variable up — a
release pins a variable SNAPSHOT taken when it was created. Either click
"Update Variables" on the release page, or cut a new release. Deploying without
that is another silent no-op.

    python3 add-octopus-var.py                       # dry-run (default)
    python3 add-octopus-var.py --apply
    python3 add-octopus-var.py --name X --value Y --env dev --apply

Prereq: `octopus login` (~/.config/octopus/cli_config.json) or OCTOPUS_API_KEY.
"""

import json
import os
import sys
import time
from pathlib import Path

try:
    import requests
except ImportError:
    sys.exit("ERROR: requests missing. pip install requests")

OCTO_URL = "https://octopus.usxpress.io"
SPACE_ID = "Spaces-2"          # DevOps space
PROJECT_SLUG = "iaac-talos"

CLI_CONFIG_CANDIDATES = [
    Path.home() / ".config" / "octopus" / "cli_config.json",
    Path.home() / ".octopus" / "cli_config.json",
]


def arg(flag, default):
    return sys.argv[sys.argv.index(flag) + 1] if flag in sys.argv else default


APPLY = "--apply" in sys.argv
VAR_NAME = arg("--name", "TF_VAR_enable_aws_iam_authenticator")
VAR_VALUE = arg("--value", "true")
ENV_NAME = arg("--env", "qa")


def load_api_key():
    for candidate in CLI_CONFIG_CANDIDATES:
        if candidate.exists():
            cfg = json.loads(candidate.read_text())
            for k in ("apikey", "ApiKey", "apiKey"):
                if cfg.get(k):
                    return cfg[k]
            for _, hv in (cfg.get("Hosts") or cfg.get("hosts") or {}).items():
                for k in ("ApiKey", "apiKey", "apikey"):
                    if hv.get(k):
                        return hv[k]
    sys.exit("ERROR: no Octopus API key. Run `octopus login` or set OCTOPUS_API_KEY.")


session = requests.Session()
session.headers.update({
    "X-Octopus-ApiKey": os.environ.get("OCTOPUS_API_KEY") or load_api_key(),
    "Content-Type": "application/json",
    "Accept": "application/json",
})


def api(method, path, **kw):
    r = session.request(method, f"{OCTO_URL}{path}", **kw)
    if not r.ok:
        sys.exit(f"ERROR {r.status_code} on {method} {path}\n{r.text[:500]}")
    return r.json() if r.text else {}


project = api("GET", f"/api/{SPACE_ID}/projects/{PROJECT_SLUG}")
varset_id = project["VariableSetId"]
print(f"Project:  {project['Id']}  ({project['Name']})")
print(f"VarSet:   {varset_id}")

envs = api("GET", f"/api/{SPACE_ID}/environments?take=200")["Items"]
env_id = next((e["Id"] for e in envs if e["Name"].lower() == ENV_NAME.lower()), None)
if not env_id:
    sys.exit(f"ERROR: no environment named '{ENV_NAME}'. Have: "
             + ", ".join(sorted(e["Name"] for e in envs)))
print(f"Env:      {env_id} ({ENV_NAME})")

current = api("GET", f"/api/{SPACE_ID}/variables/{varset_id}")
existing = current.get("Variables", [])

# Sibling check: if the project's other TF_VARs are NOT here, they live in a
# Library variable set and this is the wrong place to write.
tfvars_here = [v["Name"] for v in existing if v["Name"].startswith("TF_VAR_")]
print(f"TF_VAR_* already in this set: {len(tfvars_here)}")
if not tfvars_here:
    sys.exit("ERROR: no TF_VAR_* in the project variable set — they are probably in a\n"
             "Library variable set. Writing here would have no effect. Check the UI first.")

same_scope = [
    v for v in existing
    if v["Name"] == VAR_NAME and env_id in (v.get("Scope") or {}).get("Environment", [])
]
if same_scope:
    print(f"\nAlready present for {ENV_NAME}: {VAR_NAME} = {same_scope[0].get('Value')!r}")
    print("Nothing to do. (Change the value in the UI if it is wrong.)")
    sys.exit(0)

other_scope = [v for v in existing if v["Name"] == VAR_NAME]
for v in other_scope:
    scopes = (v.get("Scope") or {}).get("Environment", [])
    names = [e["Name"] for e in envs if e["Id"] in scopes] or ["(unscoped — applies everywhere)"]
    print(f"  note: {VAR_NAME} already exists scoped to {names} = {v.get('Value')!r}")

print(f"\nWould add:  {VAR_NAME} = {VAR_VALUE}   scope=Environment:{ENV_NAME}")

if not APPLY:
    print("\nDRY-RUN. Re-run with --apply to write.")
    sys.exit(0)

ts = time.strftime("%Y%m%d-%H%M%S")
backup_path = Path(f"/tmp/octopus-varset-{PROJECT_SLUG}-{ts}.json")
backup_path.write_text(json.dumps(current, indent=2))
print(f"Backup:   {backup_path}")

updated = dict(current)
updated["Variables"] = existing + [{
    "Name": VAR_NAME,
    "Value": VAR_VALUE,
    "Type": "String",
    "IsSensitive": False,
    "IsEditable": True,
    "Scope": {"Environment": [env_id]},
}]

api("PUT", f"/api/{SPACE_ID}/variables/{varset_id}", data=json.dumps(updated))
print(f"\n✓ Added {VAR_NAME} = {VAR_VALUE} scoped to {ENV_NAME}")
print(f"  Revert: PUT {backup_path} back to /api/{SPACE_ID}/variables/{varset_id}")
print("\n⚠️ NEXT: existing releases pin a variable snapshot. Click 'Update Variables'")
print("   on the release page, or cut a new release, BEFORE deploying — otherwise")
print("   the deploy is green and changes nothing.")

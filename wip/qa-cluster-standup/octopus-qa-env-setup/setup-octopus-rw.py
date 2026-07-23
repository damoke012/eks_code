#!/usr/bin/env python3
"""setup-octopus-rw.py — make the iaac-risingwave-onprem Octopus project able to
deploy to QA. INFRA-1624.

The project shell exists but was never configured:
  * lifecycle `devops-auto` has ONE phase (`devops`) — no qa phase, so it cannot
    deploy to qa even once variables exist;
  * ZERO variables — nothing for deploy.ps1 to read.

This does two things, each guarded:
  1. Repoints the project lifecycle to the same one iaac-talos uses (default
     `iaac-release`, which has development/qa/staging/production).
  2. Adds the QA-scoped variables deploy.ps1 needs.

deploy.ps1 (the slim RW version) reads:
  S3_BUCKET, TF_STATE_KEY, AWS_DEFAULT_REGION, TfApply, TfDestroy,
  and every TF_VAR_* (exported as env so Terraform auto-reads them).

RW's TF_VARs (from terraform/variables.tf): cluster_name, region, oidc_issuer,
namespace, service_account, s3_bucket_prefix. aws_profile is DELIBERATELY NOT
set — in Octopus, AWS auth is the worker's role, not a named profile; setting it
would make the provider look for a profile that doesn't exist on the worker.

READ-ONLY unless you pass --apply. Backs up the full variable set first, prompts
before writing, never deletes anything.

Prereq: `octopus login` or OCTOPUS_API_KEY. `pip install requests`.
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
SPACE_ID = "Spaces-2"
PROJECT_SLUG = "iaac-risingwave-onprem"
REFERENCE_SLUG = "iaac-talos"          # copy its lifecycle
QA_ENV_NAME = "qa"
APPLY = "--apply" in sys.argv

# QA-scoped variables. TF_VAR_region because RW's variable is `region`
# (iaac-talos uses aws_region — do not confuse them).
QA_VARS = {
    "S3_BUCKET":                 "lazy-tf-state-425rbol87rmn6c7m",
    "TF_STATE_KEY":              "iaac/risingwave/op-usxpress-qa.tfstate",
    "AWS_DEFAULT_REGION":        "us-east-2",
    "TfApply":                   "true",
    "TfDestroy":                 "false",
    "TF_VAR_cluster_name":       "op-usxpress-qa",
    "TF_VAR_region":             "us-east-2",
    "TF_VAR_oidc_issuer":        "d2t7d36wmf0hbm.cloudfront.net",
    "TF_VAR_namespace":          "risingwave",
    "TF_VAR_service_account":    "risingwave",
    "TF_VAR_s3_bucket_prefix":   "risingwave-state-op-usxpress-qa",
}

CLI_CONFIG_CANDIDATES = [
    Path.home() / ".config" / "octopus" / "cli_config.json",
    Path.home() / ".octopus" / "cli_config.json",
]


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
project_id, varset_id = project["Id"], project["VariableSetId"]
print(f"Project: {project_id} ({project['Name']})")
print(f"  current lifecycle: {project['LifecycleId']}")

reference = api("GET", f"/api/{SPACE_ID}/projects/{REFERENCE_SLUG}")
ref_lifecycle = reference["LifecycleId"]
print(f"  reference ({REFERENCE_SLUG}) lifecycle: {ref_lifecycle}")

envs = api("GET", f"/api/{SPACE_ID}/environments?take=200")["Items"]
qa_env = next((e for e in envs if e["Name"].lower() == QA_ENV_NAME.lower()), None)
if not qa_env:
    sys.exit(f"ERROR: environment '{QA_ENV_NAME}' not found")
qa_env_id = qa_env["Id"]
print(f"  qa env: {qa_env_id}")

# Confirm the reference lifecycle actually has a qa phase before adopting it.
lc = api("GET", f"/api/{SPACE_ID}/lifecycles/{ref_lifecycle}")
lc_envs = {e for ph in lc.get("Phases", [])
           for e in (ph.get("OptionalDeploymentTargets") or []) + (ph.get("AutomaticDeploymentTargets") or [])}
if qa_env_id not in lc_envs:
    sys.exit(f"ERROR: reference lifecycle {lc.get('Name')} has no qa phase — pick a different one")
print(f"  reference lifecycle {lc.get('Name')!r} includes qa  ✓")

ts = int(time.time())
backup = Path(f"/tmp/octopus-rw-backup-{ts}.json")
current_vars = api("GET", f"/api/{SPACE_ID}/variables/{varset_id}")
backup.write_text(json.dumps({"project": project, "variables": current_vars}, indent=2))
print(f"  backup: {backup}")

existing_qa = {
    v["Name"] for v in current_vars["Variables"]
    if qa_env_id in (v.get("Scope") or {}).get("Environment", [])
}

to_add = []
for name, value in QA_VARS.items():
    if name in existing_qa:
        print(f"    skip (already QA-scoped): {name}")
        continue
    sensitive = name in ("S3_BUCKET",) is False and False  # none here are secret
    to_add.append({
        "Id": "", "Name": name, "Value": value,
        "Description": "RisingWave QA deploy (INFRA-1624)",
        "Scope": {"Environment": [qa_env_id]},
        "IsEditable": True, "IsSensitive": False, "Prompt": None, "Type": "String",
    })

lifecycle_change = project["LifecycleId"] != ref_lifecycle

print("\n=== PLAN ===")
if lifecycle_change:
    print(f"  lifecycle: {project['LifecycleId']} -> {ref_lifecycle} ({lc.get('Name')})")
else:
    print("  lifecycle: already correct")
print(f"  add {len(to_add)} QA-scoped variable(s):")
for v in to_add:
    print(f"      {v['Name']:26} = {v['Value']}")

if not APPLY:
    print("\nDRY RUN. Re-run with --apply to write. Nothing changed.")
    sys.exit(0)

if not lifecycle_change and not to_add:
    print("\nNothing to do.")
    sys.exit(0)

if input(f"\nApply to {PROJECT_SLUG}? (yes/NO): ").strip().lower() != "yes":
    print("Aborted.")
    sys.exit(0)

if lifecycle_change:
    project["LifecycleId"] = ref_lifecycle
    api("PUT", f"/api/{SPACE_ID}/projects/{project_id}", data=json.dumps(project))
    print("  ✓ lifecycle updated")

if to_add:
    current_vars["Variables"] = current_vars["Variables"] + to_add
    api("PUT", f"/api/{SPACE_ID}/variables/{varset_id}", data=json.dumps(current_vars))
    print(f"  ✓ added {len(to_add)} variable(s)")

print(f"\nDone. Revert with the backup at {backup} if needed.")
print("Next: push a branch so CI (.github/workflows/octo.yaml) builds a release,")
print("      then deploy that release to qa. deploy.ps1 must exist in deploy/.")

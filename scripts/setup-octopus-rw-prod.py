#!/usr/bin/env python3
"""INFRA-1674 — add production-scoped variables to the iaac-risingwave-onprem
Octopus project.

Modelled on wip/qa-cluster-standup/octopus-qa-env-setup/setup-octopus-rw.py, which
did the same for QA under INFRA-1624. Verified 2026-09-01 that nothing else is
needed:

  * environment `production` exists (Environments-41)
  * lifecycle `iaac-release` (Lifecycles-42) already has a `production` phase
  * all 11 existing variables are scoped to `qa` only — no production scope at all

TfApply is DELIBERATELY NOT SET HERE. There is no global TfApply and none scoped to
production, so the first prod deploy is plan-only on its own. Read that plan (expect
all creates, zero destroys), then arm with a production-scoped TfApply=true, redeploy,
and delete the scoped entry afterwards. Arming and disarming stays a separate,
deliberate act — never a side effect of adding configuration.

TF_VAR_aws_profile is deliberately absent: on an Octopus worker AWS auth is the
worker's role, and setting a profile makes the provider look for one that is not there.

READ-ONLY unless --apply. Backs up the variable set first, never deletes, and skips
any name already scoped to production.

Run on WSL. Prereq: `octopus login` or OCTOPUS_API_KEY.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

OCTO_URL = "https://octopus.usxpress.io"
SPACE_ID = "Spaces-2"
PROJECT_SLUG = "iaac-risingwave-onprem"
PROD_ENV_NAME = "production"
APPLY = "--apply" in sys.argv

PROD_VARS = {
    "S3_BUCKET":              "lazy-tf-state-425rbol87rmn6c7m",
    "TF_STATE_KEY":           "iaac/risingwave/op-usxpress-prod.tfstate",
    "AWS_DEFAULT_REGION":     "us-east-2",
    "TfDestroy":              "false",
    "TF_VAR_cluster_name":    "op-usxpress-prod",
    "TF_VAR_region":          "us-east-2",
    "TF_VAR_oidc_issuer":     "d3rxit8f4yvshu.cloudfront.net",
    "TF_VAR_namespace":       "risingwave",
    "TF_VAR_service_account": "risingwave",
    "TF_VAR_s3_bucket_prefix": "risingwave-state-op-usxpress-prod",
}

# No value for production may carry another environment's identity. This is the
# check that would have caught op-prod's dev hostnames and dev worker IPs.
FOREIGN = ["op-usxpress-qa", "op-usxpress-dev", "op-qa", "op-dev",
           "d2t7d36wmf0hbm", "d3a7wcnazdrd6p", "527101283767", "700736442855",
           "786352483360"]


def load_api_key():
    if os.environ.get("OCTOPUS_API_KEY"):
        return os.environ["OCTOPUS_API_KEY"]
    for c in (Path.home() / ".config/octopus/cli_config.json",
              Path.home() / ".octopus/cli_config.json"):
        if c.exists():
            cfg = json.loads(c.read_text())
            for k in ("apikey", "ApiKey", "apiKey"):
                if cfg.get(k):
                    return cfg[k]
            for _, hv in (cfg.get("Hosts") or cfg.get("hosts") or {}).items():
                for k in ("ApiKey", "apiKey", "apikey"):
                    if isinstance(hv, dict) and hv.get(k):
                        return hv[k]
    sys.exit("ERROR: no Octopus API key. Run `octopus login` or set OCTOPUS_API_KEY.")


KEY = load_api_key()


def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(OCTO_URL + path, data=data, method=method,
                                 headers={"X-Octopus-ApiKey": KEY,
                                          "Content-Type": "application/json",
                                          "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"ERROR {e.code} on {method} {path}\n{e.read()[:400].decode(errors='replace')}")


# ── foreign-literal gate, before anything touches Octopus ────────────────────
bad = [(n, v) for n, v in PROD_VARS.items() for f in FOREIGN if f in v]
if bad:
    for n, v in bad:
        print(f"  FATAL  {n} = {v}  carries another environment's identifier")
    sys.exit("ABORT: refusing to write foreign values into production scope.")

project = api("GET", f"/api/{SPACE_ID}/projects/{PROJECT_SLUG}")
varset_id = project["VariableSetId"]
print(f"Project:   {project['Id']}  ({project['Name']})")

envs = api("GET", f"/api/{SPACE_ID}/environments?take=200")["Items"]
prod = next((e for e in envs if e["Name"].lower() == PROD_ENV_NAME), None)
if not prod:
    sys.exit(f"ERROR: environment '{PROD_ENV_NAME}' not found in {SPACE_ID}")
prod_id = prod["Id"]
print(f"Env:       {prod_id}  ({prod['Name']})")

lc = api("GET", f"/api/{SPACE_ID}/lifecycles/{project['LifecycleId']}")
lc_envs = {e for ph in lc.get("Phases", [])
           for e in (ph.get("OptionalDeploymentTargets") or []) + (ph.get("AutomaticDeploymentTargets") or [])}
if prod_id not in lc_envs:
    sys.exit(f"ERROR: lifecycle {lc.get('Name')!r} has no production phase — the variables\n"
             f"       would apply but the project could not deploy there.")
print(f"Lifecycle: {lc.get('Name')!r} includes production  ok")

varset = api("GET", f"/api/{SPACE_ID}/variables/{varset_id}")
existing = varset.get("Variables", [])

already = {v["Name"] for v in existing
           if prod_id in ((v.get("Scope") or {}).get("Environment") or [])}

# A TfApply already scoped to production means the next deploy applies with nobody
# arming it. Refuse rather than add configuration alongside a live trigger.
for v in existing:
    if v["Name"] == "TfApply" and prod_id in ((v.get("Scope") or {}).get("Environment") or []):
        sys.exit(f"ABORT: TfApply is ALREADY scoped to production (= {v.get('Value')!r}).\n"
                 "       A prod deploy would apply unprompted. Resolve that first.")
print("TfApply:   not scoped to production — the first prod deploy will be plan-only  ok")

ts = time.strftime("%Y%m%dT%H%M%S")
backup = Path(f"/tmp/octopus-rw-prod-backup-{ts}.json")
backup.write_text(json.dumps({"project": project, "variables": varset}, indent=2))
print(f"Backup:    {backup}\n")

to_add = []
for name, value in PROD_VARS.items():
    if name in already:
        print(f"  skip (already production-scoped)  {name}")
        continue
    print(f"  ADD  {name:<26} = {value}")
    to_add.append({"Name": name, "Value": value, "IsSensitive": False,
                   "IsEditable": True, "Scope": {"Environment": [prod_id]},
                   "Prompt": None})

if not to_add:
    print("\nNothing to add.")
    sys.exit(0)

if not APPLY:
    print(f"\nDry run — {len(to_add)} variables would be added. Pass --apply to write.")
    sys.exit(0)

varset["Variables"] = existing + to_add
api("PUT", f"/api/{SPACE_ID}/variables/{varset_id}", varset)
print(f"\nWrote {len(to_add)} production-scoped variables.")
print(f"Revert: PUT {backup} back to /api/{SPACE_ID}/variables/{varset_id}")
print("\nNext: create a release, deploy to production, and READ THE PLAN.")
print("Expect all creates and zero destroys. Any destroy = stop.")

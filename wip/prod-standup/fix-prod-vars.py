#!/usr/bin/env python3
"""fix-prod-vars.py — close the remaining prod-scoped variable gaps.

Three changes, each independently skippable, dry-run by default:

  1. TF_VAR_irsa_oidc_bucket_name  ""  ->  op-usxpress-prod-irsa-oidc-v2
     Currently EMPTY for production while dev/qa both have theirs. With
     enable_irsa=true and no bucket name, modules/irsa builds its OIDC
     discovery bucket with an empty name.

  2. TF_VAR_worker_pools  system.memory_mb  8192 -> 12288
     The QA bootstrap checklist sets a 12 GB worker floor after the
     2026-06-17 OOM cascade (workers were 4 GB). Prod's system pool
     inherited 8 GB by mirroring QA. platform (16 GB) and application
     (32 GB) already clear the floor. Costs 2 x 4 GB across the pool.

  3. TF_VAR_etcd_quota_backend_bytes -> 8589934592 (8 GiB)
     Checklist: ">= 8 GB (raise from default 2 GB to prevent mon/etcd disk
     pressure issues)". ONLY applied with --with-etcd-quota, because the
     variable must exist in the Terraform module first — an unknown TF_VAR_*
     is silently ignored, which would look set and do nothing.
     Verify first:  git grep -n quota_backend -- deploy/terraform

    python3 fix-prod-vars.py                     # dry-run
    python3 fix-prod-vars.py --apply             # items 1 + 2
    python3 fix-prod-vars.py --apply --with-etcd-quota   # + item 3

Backs the variable set up to /tmp before writing. Idempotent.
Does NOT touch enable_irsa — that flag is one-way and stays a deliberate,
separate action.
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
PROJECT_SLUG = "iaac-talos"
PROD_ENV_NAME = "production"

APPLY = "--apply" in sys.argv
WITH_ETCD = "--with-etcd-quota" in sys.argv

OIDC_BUCKET = "op-usxpress-prod-irsa-oidc-v2"
SYSTEM_POOL_MEMORY_MB = 12288          # 12 GB floor from the QA checklist
ETCD_QUOTA_BYTES = "8589934592"        # 8 GiB

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


envs = {e["Id"]: e["Name"] for e in api("GET", f"/api/{SPACE_ID}/environments?take=200")["Items"]}
prod_env_id = next((eid for eid, n in envs.items() if n.lower() == PROD_ENV_NAME), None)
if not prod_env_id:
    sys.exit(f"ERROR: no environment named {PROD_ENV_NAME!r}")

project = api("GET", f"/api/{SPACE_ID}/projects/{PROJECT_SLUG}")
varset = api("GET", f"/api/{SPACE_ID}/variables/{project['VariableSetId']}")
variables = varset["Variables"]


def prod_var(name):
    for v in variables:
        if v["Name"] == name and prod_env_id in ((v.get("Scope") or {}).get("Environment") or []):
            return v
    return None


changes = []

# ---- 1. OIDC bucket name ----------------------------------------------------
v = prod_var("TF_VAR_irsa_oidc_bucket_name")
if v is None:
    print("  ! TF_VAR_irsa_oidc_bucket_name has no production-scoped entry — will ADD")
    changes.append(("add", "TF_VAR_irsa_oidc_bucket_name", "", OIDC_BUCKET))
elif (v.get("Value") or "").strip() == OIDC_BUCKET:
    print(f"  = TF_VAR_irsa_oidc_bucket_name already {OIDC_BUCKET}")
else:
    changes.append(("set", "TF_VAR_irsa_oidc_bucket_name", v.get("Value") or "<empty>", OIDC_BUCKET))

# ---- 2. system pool RAM -----------------------------------------------------
wp = prod_var("TF_VAR_worker_pools")
if wp is None:
    print("  ! TF_VAR_worker_pools missing for production — skipping pool change")
else:
    pools = json.loads(wp["Value"])
    cur = pools.get("system", {}).get("memory_mb")
    if cur == SYSTEM_POOL_MEMORY_MB:
        print(f"  = system pool already {SYSTEM_POOL_MEMORY_MB} MB")
    elif cur is None:
        print("  ! no 'system' pool found — skipping")
    else:
        pools["system"]["memory_mb"] = SYSTEM_POOL_MEMORY_MB
        changes.append(("set", "TF_VAR_worker_pools",
                        f"system.memory_mb={cur}",
                        f"system.memory_mb={SYSTEM_POOL_MEMORY_MB}"))
        new_pools_json = json.dumps(pools)

# ---- 3. etcd quota ----------------------------------------------------------
if WITH_ETCD:
    v = prod_var("TF_VAR_etcd_quota_backend_bytes")
    if v is None:
        changes.append(("add", "TF_VAR_etcd_quota_backend_bytes", "<absent>", ETCD_QUOTA_BYTES))
    elif (v.get("Value") or "").strip() == ETCD_QUOTA_BYTES:
        print(f"  = TF_VAR_etcd_quota_backend_bytes already {ETCD_QUOTA_BYTES}")
    else:
        changes.append(("set", "TF_VAR_etcd_quota_backend_bytes", v.get("Value"), ETCD_QUOTA_BYTES))
else:
    print("  - etcd quota skipped (pass --with-etcd-quota AFTER confirming the TF "
          "module\n    actually declares the variable; an unknown TF_VAR_* is "
          "silently ignored)")

print(f"\n=== {len(changes)} change(s) ===")
for kind, name, before, after in changes:
    print(f"  {kind.upper():4} {name}")
    print(f"        from: {before}")
    print(f"        to:   {after}")

if not changes:
    sys.exit("\nNothing to do.")

if not APPLY:
    sys.exit("\n[DRY-RUN] No changes made. Re-run with --apply to write.")

ts = int(time.time())
backup = Path(f"/tmp/octopus-varset-prod-fixvars-{ts}.json")
backup.write_text(json.dumps(varset, indent=2))
print(f"\nBackup: {backup}")

if input(f"Apply {len(changes)} change(s)? (yes/NO): ").strip().lower() != "yes":
    sys.exit("Aborted. No changes made.")

for kind, name, _, after in changes:
    if name == "TF_VAR_worker_pools":
        prod_var(name)["Value"] = new_pools_json
    elif kind == "set":
        prod_var(name)["Value"] = after
    else:
        variables.append({
            "Id": "", "Name": name, "Value": after,
            "Description": "Added by fix-prod-vars.py (INFRA-1589)",
            "Scope": {"Environment": [prod_env_id]},
            "IsEditable": True, "IsSensitive": False, "Prompt": None, "Type": "String",
        })

varset["Variables"] = variables
api("PUT", f"/api/{SPACE_ID}/variables/{project['VariableSetId']}", data=json.dumps(varset))
print(f"\n✓ Applied {len(changes)} change(s).")
print(f"  Revert: PUT {backup} back to /api/{SPACE_ID}/variables/{project['VariableSetId']}")

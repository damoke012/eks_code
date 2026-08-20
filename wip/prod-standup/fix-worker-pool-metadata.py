#!/usr/bin/env python3
"""fix-worker-pool-metadata.py — close finding F3: prod's worker pools have no
node labels or taints outside the `system` pool.

THE BUG (see BUILD-FINDINGS-2026-07-29.md F3)
  argocd-redis-secret-init has nodeSelector pool=platform and could not schedule:
    0/13 nodes available: 10 didn't match selector, 3 control-plane taint
  Every node was rejected, including talos-wk-op-prod-platform-1/2/3.

  The Terraform is CORRECT. local.worker_pool_metadata (deploy/terraform/main.tf:53)
  flattens sort(keys(pools)) x count -> one entry per worker, index-aligned with
  worker_vm_names. modules/talos/main.tf:211,213 read .labels and .taints from it.

  The gap is the INPUT: prod's TF_VAR_worker_pools JSON only carries a `labels`
  key on the `system` entry. `taints` is missing the same way — that one has NO
  visible symptom, which makes it the more dangerous half: nothing currently keeps
  general workloads off the platform and application pools.

WHAT THIS DOES
  Mirrors QA's per-pool `labels` and `taints` into prod's worker_pools JSON,
  pool-key by pool-key. Labels/taints are keyed on pool NAME (pool=platform), not
  on environment, so QA's values are directly reusable — but every copied value is
  scanned for foreign-env literals first and the run BLOCKS if any is found.

  Never invents taints. If QA has no taints for a pool, prod gets none — inventing
  scheduling constraints from nothing is how you strand a workload.

  Labels ARE synthesised as a last resort ({"pool": "<key>"}) when QA has none
  either, because that is the contract the manifests already depend on. Requires
  --synthesize-labels so it is never silent.

USAGE
    python3 fix-worker-pool-metadata.py                      # dry-run + diff vs QA
    python3 fix-worker-pool-metadata.py --apply
    python3 fix-worker-pool-metadata.py --apply --synthesize-labels

  Backs the variable set up to /tmp before writing. Idempotent — re-running after a
  successful apply reports "nothing to do".

AFTER APPLYING
  This changes Talos machine config, so labels land on a REBUILD, not on the
  running cluster. The hand-applied labels on op-usxpress-prod stay correct in the
  meantime. Verify after the next build:

      kubectl get nodes -L pool          # expect system/platform/application
      kubectl describe node <platform-1> | grep -A5 Taints
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
REF_ENV_NAME = "qa"
VAR_NAME = "TF_VAR_worker_pools"

APPLY = "--apply" in sys.argv
SYNTH = "--synthesize-labels" in sys.argv

# A copied value containing any of these is env-specific and must NOT be mirrored.
FOREIGN = ["op-usxpress-qa", "op-usxpress-dev", "527101283767", "700736442855",
           "usxpress-qa", "usxpress-dev", "dpl2", "dpl."]

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
prod_env_id = next((i for i, n in envs.items() if n.lower() == PROD_ENV_NAME), None)
ref_env_id = next((i for i, n in envs.items() if n.lower() == REF_ENV_NAME), None)
if not prod_env_id:
    sys.exit(f"ERROR: no environment named {PROD_ENV_NAME!r}")
if not ref_env_id:
    sys.exit(f"ERROR: no environment named {REF_ENV_NAME!r} to mirror from")

project = api("GET", f"/api/{SPACE_ID}/projects/{PROJECT_SLUG}")
varset = api("GET", f"/api/{SPACE_ID}/variables/{project['VariableSetId']}")
variables = varset["Variables"]


def scoped_var(name, env_id):
    for v in variables:
        if v["Name"] == name and env_id in ((v.get("Scope") or {}).get("Environment") or []):
            return v
    return None


prod_var = scoped_var(VAR_NAME, prod_env_id)
ref_var = scoped_var(VAR_NAME, ref_env_id)

if prod_var is None:
    sys.exit(f"ERROR: {VAR_NAME} has no production-scoped entry. Nothing to patch.")
if ref_var is None:
    sys.exit(f"ERROR: {VAR_NAME} has no {REF_ENV_NAME}-scoped entry to mirror from.\n"
             f"       Cannot infer correct labels/taints without a reference. Aborting.")

prod_pools = json.loads(prod_var["Value"])
ref_pools = json.loads(ref_var["Value"])

# ---- report -----------------------------------------------------------------
print(f"=== {VAR_NAME}: production vs {REF_ENV_NAME} ===\n")
all_keys = sorted(set(prod_pools) | set(ref_pools))
for k in all_keys:
    p = prod_pools.get(k) or {}
    q = ref_pools.get(k) or {}
    print(f"  {k}")
    print(f"    prod  count={p.get('count')!s:<4} labels={p.get('labels')!r} taints={p.get('taints')!r}")
    print(f"    {REF_ENV_NAME:<5} count={q.get('count')!s:<4} labels={q.get('labels')!r} taints={q.get('taints')!r}")

if set(prod_pools) != set(ref_pools):
    print(f"\n  ! pool KEYS differ: prod={sorted(prod_pools)} {REF_ENV_NAME}={sorted(ref_pools)}")
    print("    Only keys present in prod are patched; extra QA pools are ignored.")

# ---- plan -------------------------------------------------------------------
changes = []
blocked = []

for k in sorted(prod_pools):
    p = prod_pools[k]
    q = ref_pools.get(k, {})

    if not p.get("labels"):
        src = q.get("labels")
        if src:
            changes.append((k, "labels", src, f"mirrored from {REF_ENV_NAME}"))
        elif SYNTH:
            changes.append((k, "labels", {"pool": k}, "synthesised"))
        else:
            blocked.append(f"{k}.labels — absent in prod AND in {REF_ENV_NAME}; "
                           f"pass --synthesize-labels to write {{'pool': '{k}'}}")

    if not p.get("taints"):
        src = q.get("taints")
        if src:
            changes.append((k, "taints", src, f"mirrored from {REF_ENV_NAME}"))
        # deliberately no synthesis branch for taints

# every mirrored value must be env-neutral
for k, field, value, origin in changes:
    blob = json.dumps(value)
    hits = [f for f in FOREIGN if f in blob]
    if hits:
        blocked.append(f"{k}.{field} carries foreign-env literal(s) {hits}: {blob} "
                       f"— fix the {REF_ENV_NAME} value or set prod's by hand")

print(f"\n=== {len(changes)} change(s) ===")
for k, field, value, origin in changes:
    print(f"  SET  {k}.{field} = {json.dumps(value)}   ({origin})")

if blocked:
    print(f"\n=== {len(blocked)} BLOCKER(S) ===")
    for b in blocked:
        print(f"  ! {b}")
    sys.exit("\nRefusing to write while blockers remain.")

if not changes:
    sys.exit("\nNothing to do — every prod pool already carries labels, and taints "
             "match the reference.")

if not APPLY:
    sys.exit("\n[DRY-RUN] No changes made. Re-run with --apply to write.")

# ---- apply ------------------------------------------------------------------
ts = int(time.time())
backup = Path(f"/tmp/octopus-varset-prod-poolmeta-{ts}.json")
backup.write_text(json.dumps(varset, indent=2))
print(f"\nBackup: {backup}")

print("\nThis changes Talos MACHINE CONFIG. Labels/taints land on a REBUILD, not on")
print("the running cluster. The hand-applied labels stay correct in the meantime.")
if input(f"\nApply {len(changes)} change(s) to production {VAR_NAME}? (yes/NO): ").strip().lower() != "yes":
    sys.exit("Aborted. No changes made.")

for k, field, value, _ in changes:
    prod_pools[k][field] = value

prod_var["Value"] = json.dumps(prod_pools)
varset["Variables"] = variables
api("PUT", f"/api/{SPACE_ID}/variables/{project['VariableSetId']}", data=json.dumps(varset))

print(f"\n✓ Applied {len(changes)} change(s).")
print(f"  Revert: PUT {backup} back to /api/{SPACE_ID}/variables/{project['VariableSetId']}")
print("\nVerify after the next build:")
print("  kubectl get nodes -L pool")
print("  kubectl describe node talos-wk-op-prod-platform-1 | grep -A5 Taints")

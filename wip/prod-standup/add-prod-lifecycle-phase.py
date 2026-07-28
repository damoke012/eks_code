#!/usr/bin/env python3
"""add-prod-lifecycle-phase.py — add a `production` phase to Lifecycles-1502.

This is the SAME move dev and QA each needed. From the dev build runbook,
Issue 1:

    Problem: The feature channel lifecycle (iaac-feature-manual) only had
             "dpl" as a deployment target
    Fix:     Updated lifecycle Lifecycles-1502 via Octopus API to add
             "development"
    Command: PUT /api/Spaces-2/lifecycles/Lifecycles-1502

QA was added the same way, which is why the lifecycle now reads
development -> dpl -> qa. Prod needs `production` appended.

This is the whole unblock. It means the ALREADY-BUILT release
`0.1.0-refactor-multi-env-parameterization.1.208` — which contains the SSM
validation fix (c9a6ae2) — deploys straight to production. No merge to master,
no CI rebuild, no release-channel detour.

    python3 add-prod-lifecycle-phase.py           # dry-run: show the change
    python3 add-prod-lifecycle-phase.py --apply   # write it

Backs the lifecycle up to /tmp before writing. Idempotent: refuses to add a
second production phase if one already exists.

Prereq: `octopus login` or OCTOPUS_API_KEY. Run on WSL.
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
LIFECYCLE_ID = "Lifecycles-1502"          # iaac-feature-manual (feature channel)
PROD_ENV_NAME = "production"              # Environments-41

APPLY = "--apply" in sys.argv

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
    sys.exit(f"ERROR: no environment named {PROD_ENV_NAME!r}.")

lc = api("GET", f"/api/{SPACE_ID}/lifecycles/{LIFECYCLE_ID}")
print(f"Lifecycle: {lc['Name']} ({lc['Id']})")
print("\nCurrent phases:")
for i, ph in enumerate(lc.get("Phases") or []):
    targets = (ph.get("AutomaticDeploymentTargets") or []) + (ph.get("OptionalDeploymentTargets") or [])
    kind = "optional" if ph.get("IsOptionalPhase") else "REQUIRED"
    print(f"  {i+1}. {ph.get('Name')}: {', '.join(envs.get(e, e) for e in targets) or '(none)'}  [{kind}]")

already = [
    ph for ph in (lc.get("Phases") or [])
    if prod_env_id in (ph.get("AutomaticDeploymentTargets") or [])
                    + (ph.get("OptionalDeploymentTargets") or [])
]
if already:
    print(f"\n✓ production is ALREADY a deployment target (phase "
          f"{already[0].get('Name')!r}). Nothing to do.")
    sys.exit(0)

# Optional phase, manual target: mirrors how `qa` sits in this lifecycle. Optional
# so it never gates promotion for dev/qa, and manual so nothing auto-deploys to
# prod — the deploy stays a deliberate click, same as every other env here.
new_phase = {
    "Name": PROD_ENV_NAME,
    "AutomaticDeploymentTargets": [],
    "OptionalDeploymentTargets": [prod_env_id],
    "MinimumEnvironmentsBeforePromotion": 0,
    "IsOptionalPhase": True,
    "ReleaseRetentionPolicy": None,
    "TentacleRetentionPolicy": None,
}

print(f"\nWill APPEND phase:")
print(f"  {len(lc.get('Phases') or []) + 1}. {PROD_ENV_NAME}: {envs[prod_env_id]} "
      f"({prod_env_id})  [optional, manual]")
print("\nEffect: release 0.1.0-refactor-multi-env-parameterization.1.208 (and any "
      "other\nfeature-channel release) becomes deployable to production from the "
      "Octopus UI.")

if not APPLY:
    print("\n[DRY-RUN] No changes made. Re-run with --apply to write.")
    sys.exit(0)

ts = int(time.time())
backup = Path(f"/tmp/octopus-lifecycle-1502-backup-{ts}.json")
backup.write_text(json.dumps(lc, indent=2))
print(f"\nBackup: {backup}")

resp = input(f"Append a '{PROD_ENV_NAME}' phase to {lc['Name']}? (yes/NO): ").strip().lower()
if resp != "yes":
    sys.exit("Aborted. No changes made.")

lc["Phases"] = (lc.get("Phases") or []) + [new_phase]
api("PUT", f"/api/{SPACE_ID}/lifecycles/{LIFECYCLE_ID}", data=json.dumps(lc))
print(f"\n✓ Added '{PROD_ENV_NAME}' phase to {lc['Name']}.")
print(f"  Revert: PUT {backup} back to /api/{SPACE_ID}/lifecycles/{LIFECYCLE_ID}")
print("\nNext: Octopus -> iaac-talos -> Releases -> "
      "0.1.0-refactor-multi-env-parameterization.1.208 -> Deploy -> production")

#!/usr/bin/env python3
"""
add-prod-vars.py — Add prod-scoped variables to the iaac-talos Octopus project.

Models add-qa-vars.py (INFRA-1585) exactly, with three deliberate differences:
  1. DRY-RUN BY DEFAULT. Prints the plan and exits. Pass --apply to write.
     (Prod is the first real execution of this path — no silent writes.)
  2. TBD GUARD. Any variable whose value still contains "TBD-PROD" ABORTS the
     apply. This is the INFRA-1623 defence in code: a placeholder must never
     reach Octopus, where it would deploy clean and fail invisibly.
  3. --diff-qa. Dumps prod-vs-QA variable names + values so you can eyeball
     drift before standing prod up. "QA mirrors prod" only holds if you check.

Prereq:
  - `octopus login` (uses ~/.config/octopus/cli_config.json) or OCTOPUS_API_KEY
  - `pip install requests`

Safety: only ADDS prod-scoped entries; never touches dev/qa-scoped variables;
skips a prod-scoped name that already exists; backs up the varset first.

    python3 add-prod-vars.py               # dry-run: show what WOULD be added
    python3 add-prod-vars.py --diff-qa     # show prod-vs-qa value drift
    python3 add-prod-vars.py --apply       # write (refuses if any TBD-PROD left)
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

# ---- Config -----------------------------------------------------------------

OCTO_URL = "https://octopus.usxpress.io"
SPACE_ID = "Spaces-2"                     # DevOps space
PROJECT_SLUG = "iaac-talos"
PROD_ENV_NAME = "production"              # DISCOVERED 2026-07-24 via --list-envs:
                                          # the prod env is named "production"
                                          # (Environments-41), NOT "prod". Override
                                          # with --env-name if this ever changes.
QA_ENV_NAME = "qa"                        # for --diff-qa (Environments-602)
# resolved after arg parse (see below), so --env-name can override


APPLY = "--apply" in sys.argv
DIFF_QA = "--diff-qa" in sys.argv
LIST_ENVS = "--list-envs" in sys.argv

# --env-name X overrides the prod environment name to match (default "prod").
# Use after --list-envs reveals the real name (e.g. "Production", "op-prod").
if "--env-name" in sys.argv:
    PROD_ENV_NAME_OVERRIDE = sys.argv[sys.argv.index("--env-name") + 1]
else:
    PROD_ENV_NAME_OVERRIDE = None

CLI_CONFIG_CANDIDATES = [
    Path.home() / ".config" / "octopus" / "cli_config.json",
    Path.home() / ".octopus" / "cli_config.json",
]

# ---- Prod variables ---------------------------------------------------------
# RESOLVED values are written. TBD-PROD-* sentinels MUST be replaced from the
# capacity/network/account plan before --apply (the guard enforces this).
#
# ⚠️ ACCOUNT: 937464026810 is inferred from "on-prem reuses the cloud per-env
# account" (op-dev→700736442855, op-qa→527101283767). CONFIRM before apply.

PROD_ACCOUNT = "937464026810"             # CONFIRM — ops-controller / usxpress-prod

PROD_VARS = {
    # Cluster identity + state
    "TF_STATE_KEY":                     "iaac/talos/op-usxpress-prod.tfstate",
    # Confirmed 2026-07-24 in the prod account (matches QA's lazy-tf-state-*
    # scheme). Final key-confirm: s3 ls .../iaac/talos/ — init fails LOUD if wrong.
    "TF_VAR_tf_state_bucket":           "lazy-tf-state-ipp58n854uhpw13x",
    "TF_VAR_cluster_name":              "op-usxpress-prod",
    "TF_VAR_aws_region":                "us-east-2",

    # Control plane (MIRRORED from QA — confirm)
    "TF_VAR_cp_cpus":                   "4",
    "TF_VAR_cp_memory_mb":              "16384",
    "TF_VAR_control_plane_name_prefix": "talos-cp-op-prod",
    # VIP self-assigned on vLAN 82 (dev .50, qa .51, prod .52), verified free
    # 2026-07-24. Networking notified, not asked. Nodes are DHCP — no IP list.
    "TF_VAR_control_plane_vip":         "10.10.82.52",
    "TF_VAR_endpoint":                  "https://10.10.82.52:6443",

    # Workers
    "TF_VAR_worker_count":              "0",
    "TF_VAR_worker_cpus":               "4",
    "TF_VAR_worker_memory_mb":          "8192",
    "TF_VAR_worker_ceph_disk_gb":       "0",
    "TF_VAR_worker_name_prefix":        "talos-wk-op-prod",

    # Storage
    "TF_VAR_disk_size_gb":              "100",

    # vSphere placement — prod-DESIGNATED infra (names say PROD). QA is
    # co-tenanting on these; prod belongs here. Dedicated vm_folder for clean
    # inventory separation. ⚠️ VERIFY datastore capacity headroom before apply
    # (QA already consumes USXD1NTXPROD-SC1 — see RUNBOOK pre-apply gate).
    "TF_VAR_datastore":                 "USXD1NTXPROD-SC1",
    "TF_VAR_network_name":              "10.10.82 (vLAN 82) Prod",
    "TF_VAR_vm_folder":                 "/KubernetesD1/TalosD1/op-usxpress-prod",
    "TF_VAR_content_library_name":      "dev-cluster",
    "TF_VAR_content_library_item_name": "talos-v#{TF_VAR_talos_version}",
    "TF_VAR_talos_version":             "1.11.1",

    # Talos secret (created during build; ARN known only after seeding)
    "TF_VAR_talosconfig_secret_arn":
        f"arn:aws:secretsmanager:us-east-2:{PROD_ACCOUNT}:secret:op-usxpress-prod/talosconfig-TBD-PROD",

    # IRSA — starts false on a greenfield (resources don't exist yet); flip true
    # in phase 2, then NEVER back to false (false = DESTROY once state has them).
    "TF_VAR_enable_irsa":               "false",
    "TF_VAR_irsa_oidc_bucket_name":     "",     # TBD-PROD when enable_irsa=true

    # Flux
    "TF_VAR_flux_target_path":          "clusters/op-usxpress-prod",
}

# Three-pool architecture — MIRRORED from QA (single-line JSON string).
PROD_VARS["TF_VAR_worker_pools"] = json.dumps({
    "system": {
        "count": 2, "cpus": 4, "memory_mb": 8192,
        "disk_size_gb": 100, "ceph_disk_gb": 0,
        "labels": {"pool": "system"}, "taints": {},
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

# ---- Discovery --------------------------------------------------------------

project = api("GET", f"/api/{SPACE_ID}/projects/{PROJECT_SLUG}")
varset_id = project["VariableSetId"]
print(f"Project:  {project['Id']}  ({project['Name']})")
print(f"VarSet:   {varset_id}")

envs = api("GET", f"/api/{SPACE_ID}/environments?take=200")["Items"]

# --list-envs: dump every environment in the space, read-only, then exit.
# Use this to find whether prod already exists under a different name before
# concluding one must be created.
if LIST_ENVS:
    print(f"\n=== all environments in {SPACE_ID} ===")
    for e in sorted(envs, key=lambda x: x["Name"].lower()):
        print(f"  {e['Id']:20} {e['Name']}")
    print("\nIf a prod-like env exists above, re-run with --env-name '<its name>'.")
    print("If not, an Octopus admin must create a prod environment and add it to the")
    print("iaac-talos lifecycle before prod vars can be scoped.")
    sys.exit(0)

prod_match_name = PROD_ENV_NAME_OVERRIDE or PROD_ENV_NAME
prod_env = next((e for e in envs if e["Name"].lower() == prod_match_name.lower()), None)
if not prod_env:
    existing = ", ".join(sorted(e["Name"] for e in envs)) or "(none)"
    sys.exit(f"ERROR: environment '{prod_match_name}' not found.\n"
             f"  Environments that DO exist: {existing}\n"
             f"  → If prod is one of the above under another name, re-run with "
             f"--env-name '<name>'.\n"
             f"  → Otherwise an Octopus admin must create a prod environment and add "
             f"it to the iaac-talos lifecycle first. Run --list-envs to see them all.")
prod_env_id = prod_env["Id"]
qa_env = next((e for e in envs if e["Name"].lower() == QA_ENV_NAME.lower()), None)
qa_env_id = qa_env["Id"] if qa_env else None
print(f"Prod env: {prod_env_id}")

current = api("GET", f"/api/{SPACE_ID}/variables/{varset_id}")

# ---- --diff-qa: show prod-intended vs live QA values ------------------------

if DIFF_QA:
    if not qa_env_id:
        sys.exit("ERROR: no 'qa' environment to diff against.")
    qa_vals = {}
    for v in current["Variables"]:
        if qa_env_id in (v.get("Scope") or {}).get("Environment", []):
            qa_vals[v["Name"]] = v["Value"]
    print("\n=== prod (intended)  vs  qa (live) ===")
    for name in sorted(PROD_VARS):
        p, q = PROD_VARS[name], qa_vals.get(name, "<none>")
        flag = "  same" if p == q else "  DIFF"
        if p == q:
            continue
        print(f"{flag}  {name}")
        print(f"        prod: {p[:90]}")
        print(f"        qa:   {q[:90]}")
    only_qa = sorted(set(qa_vals) - set(PROD_VARS))
    if only_qa:
        print(f"\n  In QA but NOT in prod set (intentional? verify): {only_qa}")
    sys.exit(0)

# ---- Backup -----------------------------------------------------------------

ts = int(time.time())
backup_path = Path(f"/tmp/octopus-varset-prod-backup-{ts}.json")
backup_path.write_text(json.dumps(current, indent=2))
print(f"Backup:   {backup_path}")

existing_prod_names = {
    v["Name"] for v in current["Variables"]
    if prod_env_id in (v.get("Scope") or {}).get("Environment", [])
}

# ---- Build additions --------------------------------------------------------

to_add, skipped = [], []
for name, value in PROD_VARS.items():
    if name in existing_prod_names:
        skipped.append(name)
        continue
    to_add.append({
        "Id": "", "Name": name, "Value": value,
        "Description": "Added by prod stand-up script (INFRA-1589)",
        "Scope": {"Environment": [prod_env_id]},
        "IsEditable": True, "IsSensitive": False, "Prompt": None, "Type": "String",
    })

print("\n=== Variables to ADD (prod-scoped) ===")
for v in to_add:
    vp = v["Value"][:80] + ("..." if len(v["Value"]) > 80 else "")
    print(f"  {v['Name']:38} = {vp}")
if skipped:
    print(f"\n=== Skipped (already prod-scoped) ===\n  " + "\n  ".join(skipped))

# ---- TBD guard — the INFRA-1623 defence ------------------------------------

tbd = [v["Name"] for v in to_add if "TBD-PROD" in v["Value"]]
if tbd:
    print(f"\n⚠️  {len(tbd)} variable(s) still hold a TBD-PROD placeholder:")
    for n in tbd:
        print(f"      {n}")
    print("These need the account/IP/vSphere plan filled in first. A placeholder in "
          "Octopus deploys clean and fails invisibly — exactly INFRA-1623.")

if not APPLY:
    print("\n[DRY-RUN] No changes made. Re-run with --apply to write.")
    print("          (--apply refuses while any TBD-PROD remains.)")
    sys.exit(0)

if tbd:
    sys.exit("\nABORT: refusing to --apply with TBD-PROD placeholders present. "
             "Fill them from the plan, then re-run.")

if not to_add:
    print("\nNothing to add. Exiting cleanly.")
    sys.exit(0)

resp = input(f"\nProceed adding {len(to_add)} prod-scoped variables? (yes/NO): ").strip().lower()
if resp != "yes":
    sys.exit("Aborted. No changes made.")

updated = dict(current)
updated["Variables"] = current["Variables"] + to_add
api("PUT", f"/api/{SPACE_ID}/variables/{varset_id}", data=json.dumps(updated))
print(f"\n✓ Added {len(to_add)} prod-scoped variables to {PROJECT_SLUG}.")
print(f"  Revert: PUT {backup_path} back to /api/{SPACE_ID}/variables/{varset_id}")

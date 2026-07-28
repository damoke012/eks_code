#!/usr/bin/env python3
"""preflight-deploy.py — read-only gate check before the first op-prod deploy.

The runbook's deploy gate has three checks. Two are Octopus API reads; this
script does both, plus three more the API can answer for free. It makes NO
changes — safe to run any time, run it again after every fix.

    python3 preflight-deploy.py

Checks:
  P1  TfApply is not already armed for production   (stale true = ungated apply)
  P2  iaac-talos lifecycle can reach `production`    (env exists != lifecycle deploys)
  P3  no deploy step is env-scoped to exclude prod   (would deploy clean, do nothing)
  P4  the 29 prod-scoped vars are present, no TBD    (what --apply wrote, verified)
  P5  no foreign-env literal in a prod-scoped value  (gate B5, applied to Octopus)

Not checkable here — the one gate you must do by hand:
  datastore USXD1NTXPROD-SC1 headroom for prod's ~5 TB ON TOP of QA's usage.
  vSphere UI -> Datastores -> USXD1NTXPROD-SC1 -> Free space. (govc not installed.)

Prereq: `octopus login` (~/.config/octopus/cli_config.json) or OCTOPUS_API_KEY.
Run on WSL — the codespace has no Octopus credential (deliberate token isolation).

Exit 0 = all automated gates pass. Exit 1 = at least one BLOCKER.
"""

import json
import os
import sys
from pathlib import Path

try:
    import requests
except ImportError:
    sys.exit("ERROR: requests missing. pip install requests")

OCTO_URL = "https://octopus.usxpress.io"
SPACE_ID = "Spaces-2"
PROJECT_SLUG = "iaac-talos"
PROD_ENV_NAME = "production"          # Environments-41, discovered 2026-07-24

# Mirrors PROD_VARS in add-prod-vars.py. Kept as a literal rather than imported
# because importing that module fires its own API calls. Drift is caught in both
# directions: missing names AND unexpected extras are both reported.
EXPECTED_PROD_VARS = {
    "TF_STATE_KEY", "TF_VAR_tf_state_bucket", "TF_VAR_cluster_name",
    "TF_VAR_aws_region", "TF_VAR_cp_cpus", "TF_VAR_cp_memory_mb",
    "TF_VAR_control_plane_name_prefix", "TF_VAR_control_plane_vip",
    "TF_VAR_endpoint", "TF_VAR_worker_count", "TF_VAR_worker_cpus",
    "TF_VAR_worker_memory_mb", "TF_VAR_worker_ceph_disk_gb",
    "TF_VAR_worker_name_prefix", "TF_VAR_disk_size_gb", "TF_VAR_datastore",
    "TF_VAR_network_name", "TF_VAR_vm_folder", "TF_VAR_content_library_name",
    "TF_VAR_content_library_item_name", "TF_VAR_talos_version",
    "TF_VAR_talosconfig_secret_arn", "TF_VAR_grafana_admin_secret_arn",
    "TF_VAR_grafana_azure_ad_secret_arn", "TF_VAR_manage_platform_secret_values",
    "TF_VAR_enable_irsa", "TF_VAR_irsa_oidc_bucket_name",
    "TF_VAR_flux_target_path", "TF_VAR_worker_pools",
}

# Phase 1 deliberately ships these empty — enable_irsa=false means the module
# never consumes them (secrets-values.tf gates on it). Empty here is CORRECT;
# empty anywhere else is a defaulted-to-blank variable, which is a blocker.
EXPECTED_EMPTY = {
    "TF_VAR_talosconfig_secret_arn", "TF_VAR_grafana_admin_secret_arn",
    "TF_VAR_grafana_azure_ad_secret_arn", "TF_VAR_irsa_oidc_bucket_name",
}

# Gate B5, applied to variable values instead of git. A prod-scoped variable
# holding a QA/dev literal deploys clean and points prod at the wrong thing.
FOREIGN_LITERALS = [
    "op-usxpress-qa", "op-usxpress-dev",
    "10.10.82.50", "10.10.82.51",
    "527101283767", "700736442855",
]

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
    sys.exit("ERROR: no Octopus API key. Run `octopus login` or set OCTOPUS_API_KEY.\n"
             "       (Run this on WSL — the codespace has no Octopus credential.)")


session = requests.Session()
session.headers.update({
    "X-Octopus-ApiKey": os.environ.get("OCTOPUS_API_KEY") or load_api_key(),
    "Accept": "application/json",
})


def api(path):
    r = session.get(f"{OCTO_URL}{path}")
    if not r.ok:
        return {"__error__": f"{r.status_code} {r.text[:200]}"}
    return r.json() if r.text else {}


RELEASES = "--releases" in sys.argv

blockers, warnings = [], []


def blocker(gate, msg):
    blockers.append(f"{gate}: {msg}")
    print(f"  ⛔ BLOCKER  {msg}")


def warn(gate, msg):
    warnings.append(f"{gate}: {msg}")
    print(f"  ⚠️  WARN     {msg}")


def ok(msg):
    print(f"  ✓  {msg}")


# ---- Discovery --------------------------------------------------------------

project = api(f"/api/{SPACE_ID}/projects/{PROJECT_SLUG}")
if "__error__" in project:
    sys.exit(f"ERROR reading project {PROJECT_SLUG}: {project['__error__']}")

envs = {e["Id"]: e["Name"] for e in api(f"/api/{SPACE_ID}/environments?take=200").get("Items", [])}
prod_env_id = next((eid for eid, n in envs.items() if n.lower() == PROD_ENV_NAME), None)

print("=" * 78)
print(f"op-prod deploy preflight — {project['Name']} ({project['Id']})")
print("=" * 78)
print(f"  space      : {SPACE_ID}")
print(f"  prod env   : {prod_env_id} ({PROD_ENV_NAME})")
print(f"  varset     : {project.get('VariableSetId')}")
print(f"  git-backed : {project.get('IsVersionControlled')}")
if not prod_env_id:
    sys.exit(f"\nERROR: no environment named '{PROD_ENV_NAME}'. Run "
             f"add-prod-vars.py --list-envs.")

# ---- --releases: what ref does a release actually get built from? -----------
# The project is NOT git-backed, so a release pins PACKAGE versions rather than
# a git ref. The branch/commit behind a package lives in Octopus build
# information, published by whatever CI built it. This answers "if I cut a prod
# release today, does it contain the multi-env work or master's older code?"

if RELEASES:
    rels = api(f"/api/{SPACE_ID}/projects/{project['Id']}/releases?take=10")
    items = rels.get("Items", [])
    if not items:
        sys.exit("No releases found for this project.")
    print(f"\n=== last {len(items)} release(s) ===")
    for r in items:
        print(f"\n  release {r.get('Version')}   assembled {r.get('Assembled')}")
        for sp in r.get("SelectedPackages") or []:
            pkg_ref = sp.get("PackageReferenceName") or sp.get("ActionName")
            ver = sp.get("Version")
            print(f"    package {pkg_ref} @ {ver}")
            bi = api(f"/api/{SPACE_ID}/build-information?packageId={pkg_ref}&filter={ver}&take=5")
            for b in (bi.get("Items") or [])[:2]:
                if b.get("Version") != ver:
                    continue
                commits = b.get("Commits") or []
                sha = (commits[0].get("Id") or "")[:8] if commits else "?"
                print(f"      branch : {b.get('Branch') or '(none recorded)'}")
                print(f"      commit : {sha}")
                print(f"      build  : {b.get('BuildUrl') or '(none)'}")
        deps = api(f"/api/{SPACE_ID}/releases/{r['Id']}/deployments?take=30")
        seen = []
        for d in deps.get("Items") or []:
            n = envs.get(d.get("EnvironmentId"), d.get("EnvironmentId"))
            if n not in seen:
                seen.append(n)
        print(f"    deployed to: {', '.join(seen) or '(never deployed)'}")
    print("\nIf 'branch' is empty everywhere, the CI publishing these packages does not")
    print("send build information — check the GitHub Actions workflow in iaac-talos, or")
    print("read the package version scheme (it usually encodes the branch or run id).")
    sys.exit(0)

varset = api(f"/api/{SPACE_ID}/variables/{project['VariableSetId']}")
variables = varset.get("Variables", [])


def scope_envs(v):
    return (v.get("Scope") or {}).get("Environment") or []


# ---- P1: TfApply not already armed for production ---------------------------

print("\n[P1] TfApply — is an apply already armed for production?")
tf_apply = [v for v in variables if v["Name"].lower() == "tfapply"]
if not tf_apply:
    warn("P1", "no TfApply variable found at all. deploy.ps1 gates on "
               "`$TfApply -eq \"true\"`, so absent == plan-only. Confirm the step "
               "reads a project variable and not a prompted/library one.")
else:
    for v in tf_apply:
        scopes = scope_envs(v)
        where = ", ".join(envs.get(e, e) for e in scopes) if scopes else "UNSCOPED (all envs)"
        value = v.get("Value")
        armed = str(value).strip().lower() == "true"
        applies_to_prod = (not scopes) or (prod_env_id in scopes)
        marker = "ARMED" if armed else "safe"
        print(f"      TfApply = {value!r}   scope: {where}   [{marker}]")
        if armed and applies_to_prod:
            blocker("P1", f"TfApply is already 'true' for production (scope: {where}). "
                          f"A deploy would apply WITHOUT a plan review. Set it false "
                          f"before creating the release.")
        elif armed:
            warn("P1", f"TfApply is 'true' but scoped to {where} — not prod, so the "
                       f"first prod deploy is plan-only as intended. Note it stays "
                       f"armed for {where}.")
    if not any(str(v.get("Value")).strip().lower() == "true" for v in tf_apply):
        ok("TfApply is not 'true' anywhere — first prod deploy will be plan-only.")

# The blast-radius note: if the only TfApply is unscoped, flipping it true to
# apply prod also arms dev and qa for the duration of that window.
unscoped_tfapply = [v for v in tf_apply if not scope_envs(v)]
if unscoped_tfapply and not any(prod_env_id in scope_envs(v) for v in tf_apply):
    print("      NOTE: TfApply is unscoped, so flipping it true to apply prod arms "
          "dev+qa too\n            for that window. Safer: ADD a production-scoped "
          "TfApply=true (most\n            specific scope wins), apply, then delete "
          "it — global stays false throughout.")

# ---- P2: lifecycle can actually reach production ----------------------------

print("\n[P2] Lifecycle — can this project deploy to production?")
lc = api(f"/api/{SPACE_ID}/lifecycles/{project['LifecycleId']}") if project.get("LifecycleId") else {}
if "__error__" in lc or not lc:
    blocker("P2", f"could not read lifecycle {project.get('LifecycleId')}.")
else:
    print(f"      lifecycle: {lc.get('Name')} ({lc.get('Id')})")
    prod_phase_idx = None
    phases = lc.get("Phases", [])
    for i, ph in enumerate(phases):
        auto = ph.get("AutomaticDeploymentTargets") or []
        opt = ph.get("OptionalDeploymentTargets") or []
        names = [envs.get(e, e) for e in auto + opt]
        blocking = "optional" if ph.get("IsOptionalPhase") else "REQUIRED"
        minenv = ph.get("MinimumEnvironmentsBeforePromotion", 0)
        print(f"      phase {i+1}. {ph.get('Name')!r}: {', '.join(names) or '(none)'} "
              f"[{blocking}, min-before-promotion={minenv}]")
        if prod_env_id in auto + opt:
            prod_phase_idx = i
            if prod_env_id in auto:
                warn("P2", f"production is an AUTOMATIC deployment target in phase "
                           f"{i+1}. Reaching this phase deploys to prod with no manual "
                           f"trigger. Confirm that is intended before creating a release.")
    if prod_phase_idx is None:
        blocker("P2", "the lifecycle has NO phase containing 'production'. Variable "
                      "scoping works, but the project cannot deploy there. Add a "
                      "production phase to the lifecycle first — this is our own "
                      "Octopus config, not another team's ask.")
    else:
        ok(f"production is reachable in phase {prod_phase_idx + 1}.")
        earlier_required = [
            (i, ph) for i, ph in enumerate(phases[:prod_phase_idx])
            if not ph.get("IsOptionalPhase")
        ]
        if earlier_required:
            names = ", ".join(f"{i+1}.{ph.get('Name')!r}" for i, ph in earlier_required)
            # CONFIRMED IN THE UI 2026-07-28: the deploy dropdown for a fresh
            # release offers dpl/development/qa and NOT production. Release
            # history showing .207 deployed to qa without development does NOT
            # disprove this — qa sits in an OPTIONAL phase, so it is reachable
            # early. production sits in REQUIRED phase 4 and is not.
            warn("P2", f"phase(s) {names} are REQUIRED and sit before production. "
                       f"production will NOT appear in the deploy dropdown until "
                       f"this release has a successful deployment to them. Deploy "
                       f"to development first — with TfApply=false that is a plan "
                       f"against dev's state and changes nothing.")

# ---- P3: no deploy step silently skips production ---------------------------

print("\n[P3] Deployment process — does any step exclude production?")
dp_id = project.get("DeploymentProcessId")
dp = api(f"/api/{SPACE_ID}/deploymentprocesses/{dp_id}") if dp_id else {}
if "__error__" in dp or not dp.get("Steps"):
    if project.get("IsVersionControlled"):
        warn("P3", "project is git-backed, so the deployment process lives in the "
                   "repo per-branch and is not readable at this endpoint. Check step "
                   "environment scoping on the op-prod branch by eye.")
    else:
        blocker("P3", f"no deployment process readable ({dp.get('__error__', 'empty')}). "
                      f"A project with no steps deploys successfully and does nothing.")
else:
    any_excluded = False
    for s in dp["Steps"]:
        for a in s.get("Actions") or []:
            inc = a.get("Environments") or []
            exc = a.get("ExcludedEnvironments") or []
            disabled = a.get("IsDisabled")
            runs = (not inc or prod_env_id in inc) and prod_env_id not in exc
            label = f"{s.get('Name')!r} / {a.get('Name')!r}"
            if disabled:
                warn("P3", f"step {label} is DISABLED — it runs for no environment.")
                any_excluded = True
            elif not runs:
                scoped_to = ", ".join(envs.get(e, e) for e in inc) or "(none)"
                blocker("P3", f"step {label} does NOT run for production "
                              f"(scoped to: {scoped_to}). The deploy would report "
                              f"success having skipped this step.")
                any_excluded = True
    if not any_excluded:
        ok(f"all {sum(len(s.get('Actions') or []) for s in dp['Steps'])} action(s) "
           f"run for production.")

# ---- P4: prod-scoped variables present, no placeholders ---------------------

print("\n[P4] Prod-scoped variables — did --apply land what we intended?")
prod_vars = {v["Name"]: v.get("Value") for v in variables if prod_env_id in scope_envs(v)}
print(f"      {len(prod_vars)} prod-scoped variable(s) found "
      f"(expected {len(EXPECTED_PROD_VARS)}).")

missing = sorted(EXPECTED_PROD_VARS - set(prod_vars))
extra = sorted(set(prod_vars) - EXPECTED_PROD_VARS)
if missing:
    blocker("P4", f"{len(missing)} expected prod var(s) MISSING: {', '.join(missing)}")
if extra:
    warn("P4", f"{len(extra)} prod-scoped var(s) not in the expected set "
               f"(added by hand?): {', '.join(extra)}")

tbd = sorted(n for n, val in prod_vars.items() if "TBD-PROD" in str(val))
if tbd:
    blocker("P4", f"placeholder still in Octopus: {', '.join(tbd)}. This is exactly "
                  f"INFRA-1623 — deploys clean, fails invisibly.")

blank = sorted(n for n, val in prod_vars.items()
               if not str(val).strip() and n not in EXPECTED_EMPTY)
if blank:
    blocker("P4", f"unexpectedly blank: {', '.join(blank)}. Phase 1 blanks only the "
                  f"4 IRSA/secret-ARN vars; anything else blank is a defaulted value.")

for n in sorted(EXPECTED_EMPTY):
    if n in prod_vars and str(prod_vars[n]).strip():
        warn("P4", f"{n} is NOT empty ({prod_vars[n]!r}). Phase 1 expects empty — a "
                   f"real ARN here means someone started phase 2.")

irsa = str(prod_vars.get("TF_VAR_enable_irsa", "")).strip().lower()
if irsa != "false":
    blocker("P4", f"TF_VAR_enable_irsa is {irsa!r}, expected 'false' for phase 1. "
                  f"True without the prod OIDC bootstrap gives a broken platform.")
else:
    ok("enable_irsa=false — phase 1 seeds nothing, no cloud dependency.")

if not missing and not tbd and not blank:
    ok("variable set matches the phase-1 model.")

# ---- P5: no foreign-env literal in a prod value -----------------------------

print("\n[P5] Foreign-env literals in prod-scoped values (gate B5):")
hits = []
for n, val in sorted(prod_vars.items()):
    for lit in FOREIGN_LITERALS:
        if lit in str(val):
            hits.append((n, lit, val))
if hits:
    for n, lit, val in hits:
        blocker("P5", f"{n} contains {lit!r} -> {str(val)[:80]}")
else:
    ok("no dev/qa cluster name, VIP, or account id in any prod-scoped value.")

# ---- Verdict ----------------------------------------------------------------

print("\n" + "=" * 78)
if blockers:
    print(f"RESULT: {len(blockers)} BLOCKER(S) — do not create the release yet.")
    for b in blockers:
        print(f"  ⛔ {b}")
else:
    print("RESULT: all automated gates PASS.")
if warnings:
    print(f"\n{len(warnings)} warning(s) — read before proceeding:")
    for w in warnings:
        print(f"  ⚠️  {w}")

print("\nSTILL MANUAL — not answerable from the Octopus API:")
print("  [ ] Datastore USXD1NTXPROD-SC1 has >~5 TB free ON TOP of QA's usage.")
print("      vSphere UI -> Datastores -> USXD1NTXPROD-SC1 -> Free space.")
print("      Prod = 13 VMs, app pool 5x(300+500) = 4 TB dominates. A datastore that")
print("      fills mid-provision leaves half-built VMs.")
print("=" * 78)

sys.exit(1 if blockers else 0)

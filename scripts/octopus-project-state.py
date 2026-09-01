#!/usr/bin/env python3
"""Read-only: what does an Octopus project ALREADY have?

Written because the prod plan said "create the environment" when
wip/prod-standup/RUNBOOK.md already recorded that it exists and is called
`production` (Environments-41), not `prod`. Look before prescribing.

GET only. Never writes, never prints a sensitive value.

Run on WSL — the codespace has no Octopus credential by design.
Prereq: `octopus login`, or OCTOPUS_API_KEY.

Usage: python3 octopus-project-state.py iaac-risingwave-onprem [--space Spaces-2]
       python3 octopus-project-state.py iaac-talos --compare iaac-risingwave-onprem
"""
import argparse
import json
import os
import sys
import urllib.request
from pathlib import Path

BASE = "https://octopus.usxpress.io"


def load_api_key():
    if os.environ.get("OCTOPUS_API_KEY"):
        return os.environ["OCTOPUS_API_KEY"]
    cfg = Path.home() / ".config" / "octopus" / "cli_config.json"
    if cfg.is_file():
        d = json.loads(cfg.read_text())
        for k in ("apikey", "ApiKey", "apiKey"):
            if d.get(k):
                return d[k]
        for v in d.values():
            if isinstance(v, dict):
                for k in ("ApiKey", "apiKey", "apikey"):
                    if v.get(k):
                        return v[k]
    sys.exit("ERROR: no Octopus API key. Run `octopus login` or set OCTOPUS_API_KEY.")


KEY = None


def api(path):
    req = urllib.request.Request(
        BASE + path, headers={"X-Octopus-ApiKey": KEY, "Accept": "application/json"})
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())


def scopes_of(var, env_by_id):
    envs = var.get("Scope", {}).get("Environment") or []
    if not envs:
        return "(all)"
    return ",".join(env_by_id.get(e, e) for e in envs)


def report(space, slug, want_vars):
    print(f"\n{'='*70}\n{slug}  (space {space})\n{'='*70}")
    try:
        project = api(f"/api/{space}/projects/{slug}")
    except Exception as e:
        print(f"  PROJECT NOT FOUND or not readable: {e}")
        return None

    print(f"  project        {project['Id']}  {project['Name']}")
    print(f"  variable set   {project['VariableSetId']}")
    print(f"  lifecycle      {project['LifecycleId']}")

    envs = api(f"/api/{space}/environments?take=200")["Items"]
    env_by_id = {e["Id"]: e["Name"] for e in envs}
    print(f"\n  environments in space ({len(envs)}):")
    for e in envs:
        print(f"      {e['Id']:<18} {e['Name']}")

    lc = api(f"/api/{space}/lifecycles/{project['LifecycleId']}")
    print(f"\n  lifecycle '{lc['Name']}' phases — an environment existing is NOT the")
    print("  same as this project being able to deploy to it:")
    if not lc.get("Phases"):
        print("      (no explicit phases — all environments, in space order)")
    for ph in lc.get("Phases", []):
        names = [env_by_id.get(i, i) for i in ph.get("OptionalDeploymentTargets", [])]
        auto = [env_by_id.get(i, i) for i in ph.get("AutomaticDeploymentTargets", [])]
        req = "REQUIRED" if ph.get("MinimumEnvironmentsBeforePromotion", 0) else "optional"
        print(f"      {ph['Name']:<24} {req:<9} optional={names} auto={auto}")

    varset = api(f"/api/{space}/variables/{project['VariableSetId']}")
    variables = varset.get("Variables", [])
    print(f"\n  project variables ({len(variables)}) — values redacted:")
    if not variables:
        print("      (none in the project set — they may live in a library variable set)")
    for v in sorted(variables, key=lambda x: (x["Name"], scopes_of(x, env_by_id))):
        sens = v.get("IsSensitive")
        val = "<sensitive>" if sens else (v.get("Value") or "")
        if not sens and len(val) > 44:
            val = val[:41] + "..."
        print(f"      {v['Name']:<32} [{scopes_of(v, env_by_id):<24}] = {val}")

    print("\n  the ones that decide this deploy:")
    for name in want_vars:
        hits = [v for v in variables if v["Name"] == name]
        if not hits:
            print(f"      ABSENT   {name}")
        for v in hits:
            val = "<sensitive>" if v.get("IsSensitive") else v.get("Value")
            print(f"      present  {name:<26} [{scopes_of(v, env_by_id)}] = {val}")

    try:
        dashboard = api(f"/api/{space}/progression/{project['Id']}")
        print("\n  most recent deployment per environment:")
        seen = {}
        for rel in dashboard.get("Releases", []):
            for env_id, deps in (rel.get("Deployments") or {}).items():
                for d in deps:
                    if env_id not in seen:
                        seen[env_id] = (rel["Release"]["Version"], d.get("State"), d.get("Created", "")[:10])
        if not seen:
            print("      (none)")
        for env_id, (ver, state, when) in seen.items():
            print(f"      {env_by_id.get(env_id, env_id):<20} {ver:<16} {state:<12} {when}")
    except Exception as e:
        print(f"\n  (progression unavailable: {e})")

    return project


def main():
    global KEY
    ap = argparse.ArgumentParser()
    ap.add_argument("project", help="project slug, e.g. iaac-risingwave-onprem")
    ap.add_argument("--space", default="Spaces-2")
    ap.add_argument("--compare", help="second project slug to print alongside")
    args = ap.parse_args()

    KEY = load_api_key()
    want = ["TfApply", "TfDestroy", "S3_BUCKET", "TF_STATE_KEY", "AWS_DEFAULT_REGION",
            "TF_VAR_cluster_name", "TF_VAR_oidc_issuer", "TF_VAR_s3_bucket_prefix",
            "TF_VAR_aws_profile", "TF_VAR_region"]

    report(args.space, args.project, want)
    if args.compare:
        report(args.space, args.compare, want)

    print("\nRead-only. Nothing was changed.")
    print("Note: a release pins a variable snapshot — a newly added project variable")
    print("does not reach an existing release until Update Variables is run on it.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

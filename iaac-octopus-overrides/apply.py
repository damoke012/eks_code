#!/usr/bin/env python3
"""
Apply Octopus library variable set overrides for OnPremise space (env=development).

Usage:
    OCTOPUS_API_KEY=API-... ./apply.py onprem-development.yaml [--dry-run]

Idempotent: upserts variables by (Name + Scope). Existing variables matching
both Name and Scope.Environment=[development] are updated; others added.

CLOUD-SAFETY: Only writes to space declared in the manifest (must be Spaces-302
OnPremise). Refuses to run against any other space. Only modifies variables
scoped to the target_environment in the manifest. Cloud-scoped variables
(no scope, qa, staging, production) are never touched.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

import yaml

OCTO = "https://octopus.usxpress.io"


def api(method, path, body=None, key=None):
    req = urllib.request.Request(
        f"{OCTO}{path}",
        data=json.dumps(body).encode() if body is not None else None,
        headers={
            "X-Octopus-ApiKey": key,
            "Content-Type": "application/json",
        },
        method=method,
    )
    try:
        with urllib.request.urlopen(req) as r:
            data = r.read()
            return json.loads(data) if data else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code} on {method} {path}: {e.read().decode()[:300]}")


def find_by_name(items, name):
    for it in items:
        if it.get("Name") == name:
            return it
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("manifest")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    key = os.environ.get("OCTOPUS_API_KEY")
    if not key:
        sys.exit("OCTOPUS_API_KEY not set")

    with open(args.manifest) as f:
        m = yaml.safe_load(f)

    space_id = m["space"]["id"]
    if space_id != "Spaces-302":
        sys.exit(
            f"REFUSING: manifest space {space_id!r} != Spaces-302 (OnPremise). "
            "This script is locked to OnPremise to enforce cloud-safety."
        )

    target_env_name = m["target_environment"]
    target_pool_name = m["target_worker_pool"]

    # Resolve env id
    envs = api("GET", f"/api/{space_id}/environments?take=100", key=key)["Items"]
    env = find_by_name(envs, target_env_name)
    if not env:
        sys.exit(f"target_environment {target_env_name!r} not found in OnPremise")
    env_id = env["Id"]

    # Resolve worker pool id (used to translate WORKER_POOL name → id)
    pools = api("GET", f"/api/{space_id}/workerpools?take=100", key=key)["Items"]
    pool = find_by_name(pools, target_pool_name)
    if not pool:
        sys.exit(f"target_worker_pool {target_pool_name!r} not found in OnPremise")
    pool_id = pool["Id"]

    print(f"OnPremise space: {space_id}")
    print(f"  env={target_env_name} -> {env_id}")
    print(f"  worker pool={target_pool_name} -> {pool_id}")
    print(f"  dry_run={args.dry_run}")
    print()

    # All library variable sets in OnPremise (resolve names → ids)
    lvs_index = {
        l["Name"]: l
        for l in api("GET", f"/api/{space_id}/libraryvariablesets?take=200", key=key)["Items"]
    }

    total_added = total_updated = total_unchanged = 0

    for lvs_name, spec in m["library_variable_sets"].items():
        lvs = lvs_index.get(lvs_name)
        if not lvs:
            sys.exit(f"library variable set {lvs_name!r} not found in OnPremise")
        vsid = lvs["VariableSetId"]
        vs = api("GET", f"/api/{space_id}/variables/{vsid}", key=key)
        existing = vs.get("Variables", [])

        print(f"== {lvs_name} ({vsid}) ==")
        for var_name, raw_value in spec["variables"].items():
            # WORKER_POOL takes the pool ID, not the name
            value = pool_id if var_name == "WORKER_POOL" else str(raw_value)

            # Find an existing variable with same name AND scope = [env_id]
            match = None
            for v in existing:
                if v["Name"] != var_name:
                    continue
                scope_envs = (v.get("Scope") or {}).get("Environment") or []
                if scope_envs == [env_id]:
                    match = v
                    break

            if match is None:
                existing.append({
                    "Name": var_name,
                    "Value": value,
                    "Scope": {"Environment": [env_id]},
                    "IsSensitive": False,
                    "IsEditable": True,
                    "Type": "String",
                })
                print(f"  + ADD    {var_name} = {value!r}  scope=env={target_env_name}")
                total_added += 1
            elif match["Value"] != value:
                old = match["Value"]
                match["Value"] = value
                print(f"  ~ UPDATE {var_name}: {old!r} -> {value!r}")
                total_updated += 1
            else:
                print(f"  = same   {var_name} = {value!r}")
                total_unchanged += 1

        if not args.dry_run:
            vs["Variables"] = existing
            api("PUT", f"/api/{space_id}/variables/{vsid}", body=vs, key=key)
            print(f"  saved {vsid}")
        print()

    print(
        f"summary: +{total_added} added  ~{total_updated} updated  ={total_unchanged} unchanged"
    )
    if args.dry_run:
        print("(dry-run, nothing written)")


if __name__ == "__main__":
    main()

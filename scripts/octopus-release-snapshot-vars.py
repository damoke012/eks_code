#!/usr/bin/env python3
"""Refresh the variable snapshot on an existing Octopus release.

A release freezes project variables at creation time. Correcting a project variable
afterwards does NOT reach a release that already exists — the deploy keeps using the
frozen value, and the task log shows the old one with no hint that a newer value exists.
This is the "Update Variables" button, over the API.

    python3 scripts/octopus-release-snapshot-vars.py iaac-risingwave-onprem 0.5.6
    python3 scripts/octopus-release-snapshot-vars.py iaac-risingwave-onprem 0.5.6 --apply

Read-only without --apply: prints what the project holds now vs what the release froze.
"""
import json, os, sys, urllib.error, urllib.request
from pathlib import Path

OCTO_URL = "https://octopus.usxpress.io"
SPACE_ID = "Spaces-2"


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
        sys.exit(f"ERROR {e.code} on {method} {path}\n{e.read()[:600].decode(errors='replace')}")


if len(sys.argv) < 3:
    sys.exit(__doc__)
project_slug, version = sys.argv[1], sys.argv[2]
apply = "--apply" in sys.argv

project = api("GET", f"/api/{SPACE_ID}/projects/{project_slug}")
release = api("GET", f"/api/{SPACE_ID}/projects/{project['Id']}/releases/{version}")
print(f"Project: {project['Id']}  Release: {release['Id']}  v{release['Version']}")

# What the PROJECT holds now, per environment scope.
envs = {e["Id"]: e["Name"] for e in api("GET", f"/api/{SPACE_ID}/environments?take=200")["Items"]}
varset = api("GET", f"/api/{SPACE_ID}/variables/{project['VariableSetId']}")
print("\nProject variables now (unencrypted, by scope):")
for v in varset.get("Variables", []):
    if v.get("IsSensitive"):
        continue
    scope = ",".join(envs.get(e, e) for e in (v.get("Scope") or {}).get("Environment") or []) or "(unscoped)"
    print(f"  {v['Name']:<28} [{scope}] = {v.get('Value')}")

# What the RELEASE froze. This is what a deploy actually runs on.
snap = api("GET", f"/api/{SPACE_ID}/variables/{release['ProjectVariableSetSnapshotId']}")
print(f"\nRelease {release['Version']} frozen snapshot ({release['ProjectVariableSetSnapshotId']}):")
for v in snap.get("Variables", []):
    if v.get("IsSensitive"):
        continue
    scope = ",".join(envs.get(e, e) for e in (v.get("Scope") or {}).get("Environment") or []) or "(unscoped)"
    print(f"  {v['Name']:<28} [{scope}] = {v.get('Value')}")

if not apply:
    print("\nRead-only. Pass --apply to refresh the release's snapshot from the project.")
    sys.exit(0)

before = release["ProjectVariableSetSnapshotId"]
api("POST", f"/api/{SPACE_ID}/releases/{release['Id']}/snapshot-variables")

# The POST returning 200 is the request being accepted. Confirm the release now points
# at a DIFFERENT snapshot — same id back means nothing was refreshed.
after_rel = api("GET", f"/api/{SPACE_ID}/releases/{release['Id']}")
after = after_rel["ProjectVariableSetSnapshotId"]
print(f"\nSnapshot {before} -> {after}")
if before == after:
    sys.exit("WARNING: the release still points at the same snapshot. Nothing was refreshed.")
after_snap = api("GET", f"/api/{SPACE_ID}/variables/{after}")
print("Refreshed snapshot now holds:")
for v in after_snap.get("Variables", []):
    if v.get("IsSensitive"):
        continue
    scope = ",".join(envs.get(e, e) for e in (v.get("Scope") or {}).get("Environment") or []) or "(unscoped)"
    print(f"  {v['Name']:<28} [{scope}] = {v.get('Value')}")

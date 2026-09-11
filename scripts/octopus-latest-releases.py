#!/usr/bin/env python3
"""List an Octopus project's most recent releases, newest first, with where each deployed.

    python3 scripts/octopus-latest-releases.py iaac-talos
    python3 scripts/octopus-latest-releases.py iaac-talos 10

Exists because every other script here wants a release VERSION and there was no way to find
one without the UI -- which produced a `<version>` placeholder in a runnable command twice
in one evening. Read-only.
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


def api(path):
    req = urllib.request.Request(OCTO_URL + path,
                                 headers={"X-Octopus-ApiKey": KEY, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        sys.exit(f"ERROR {e.code} on GET {path}\n{e.read()[:400].decode(errors='replace')}")


if len(sys.argv) < 2:
    sys.exit(__doc__)
slug = sys.argv[1]
take = int(sys.argv[2]) if len(sys.argv) > 2 else 5

project = api(f"/api/{SPACE_ID}/projects/{slug}")
envs = {e["Id"]: e["Name"] for e in api(f"/api/{SPACE_ID}/environments?take=200")["Items"]}
releases = api(f"/api/{SPACE_ID}/projects/{project['Id']}/releases?take={take}")["Items"]

print(f"{project['Name']}  ({project['Id']})\n")
for rel in releases:
    deps = api(f"/api/{SPACE_ID}/releases/{rel['Id']}/deployments?take=50")["Items"]
    where = []
    for d in deps:
        t = api(f"/api/{SPACE_ID}/tasks/{d['TaskId']}")
        where.append(f"{envs.get(d['EnvironmentId'], d['EnvironmentId'])}={t['State']}")
    print(f"  {rel['Version']:<12} {rel['Assembled'][:19]}  "
          f"{', '.join(where) if where else 'NOT DEPLOYED ANYWHERE'}")

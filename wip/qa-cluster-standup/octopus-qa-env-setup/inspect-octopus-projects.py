#!/usr/bin/env python3
"""inspect-octopus-projects.py — dump and DIFF two Octopus projects.

Purpose: `iaac-risingwave-onprem` has an Octopus project shell that was never
configured ("Cloned from Default Project"), so nothing applies its Terraform.
`iaac-talos` is the working reference. Rather than guessing what a project
needs, read the one that works and diff.

    python3 inspect-octopus-projects.py                    # talos vs risingwave
    python3 inspect-octopus-projects.py iaac-talos iaac-risingwave

READ-ONLY. Makes no changes.

Prereq: `octopus login` (uses ~/.config/octopus/cli_config.json) or OCTOPUS_API_KEY.
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

REFERENCE = sys.argv[1] if len(sys.argv) > 1 else "iaac-talos"
TARGET = sys.argv[2] if len(sys.argv) > 2 else "iaac-risingwave-onprem"

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
    "Accept": "application/json",
})


def api(path):
    r = session.get(f"{OCTO_URL}{path}")
    if not r.ok:
        return {"__error__": f"{r.status_code} {r.text[:200]}"}
    return r.json() if r.text else {}


envs = {e["Id"]: e["Name"] for e in api(f"/api/{SPACE_ID}/environments?take=200").get("Items", [])}


def describe(slug):
    out = {"slug": slug}
    p = api(f"/api/{SPACE_ID}/projects/{slug}")
    if "__error__" in p:
        out["error"] = p["__error__"]
        return out

    out["id"] = p["Id"]
    out["name"] = p["Name"]
    out["description"] = (p.get("Description") or "")[:80]
    out["lifecycle_id"] = p.get("LifecycleId")
    out["is_disabled"] = p.get("IsDisabled")
    # Config-as-code projects keep their process in git, not the Octopus DB.
    out["version_controlled"] = p.get("IsVersionControlled")

    lc = api(f"/api/{SPACE_ID}/lifecycles/{p['LifecycleId']}") if p.get("LifecycleId") else {}
    out["lifecycle_name"] = lc.get("Name")
    out["lifecycle_phases"] = [
        {
            "name": ph.get("Name"),
            "environments": [envs.get(e, e) for e in (ph.get("OptionalDeploymentTargets") or [])
                             + (ph.get("AutomaticDeploymentTargets") or [])],
        }
        for ph in lc.get("Phases", [])
    ]

    dp = api(f"/api/{SPACE_ID}/deploymentprocesses/{p['DeploymentProcessId']}") if p.get("DeploymentProcessId") else {}
    out["steps"] = [
        {
            "name": s.get("Name"),
            "actions": [
                {
                    "name": a.get("Name"),
                    "type": a.get("ActionType"),
                    "script_file": (a.get("Properties") or {}).get("Octopus.Action.Script.ScriptFileName"),
                    "package": [pk.get("PackageId") for pk in (a.get("Packages") or [])],
                    "envs": [envs.get(e, e) for e in (a.get("Environments") or [])],
                }
                for a in (s.get("Actions") or [])
            ],
        }
        for s in dp.get("Steps", [])
    ]

    vs = api(f"/api/{SPACE_ID}/variables/{p['VariableSetId']}") if p.get("VariableSetId") else {}
    variables = vs.get("Variables", [])
    out["variable_count"] = len(variables)
    scoped = {}
    for v in variables:
        for eid in ((v.get("Scope") or {}).get("Environment") or ["<unscoped>"]):
            scoped.setdefault(envs.get(eid, eid), []).append(v["Name"])
    out["variables_by_env"] = {k: sorted(set(vs_)) for k, vs_ in sorted(scoped.items())}
    return out


ref = describe(REFERENCE)
tgt = describe(TARGET)

for label, d in (("REFERENCE (working)", ref), ("TARGET (broken)", tgt)):
    print("=" * 78)
    print(f"{label}: {d['slug']}")
    print("=" * 78)
    if "error" in d:
        print(f"  ERROR: {d['error']}\n")
        continue
    print(f"  id                : {d['id']}")
    print(f"  description       : {d['description']!r}")
    print(f"  disabled          : {d['is_disabled']}")
    print(f"  version-controlled: {d['version_controlled']}")
    print(f"  lifecycle         : {d['lifecycle_name']}")
    for ph in d["lifecycle_phases"]:
        print(f"      phase {ph['name']!r}: {', '.join(ph['environments']) or '(none)'}")
    print(f"  deployment steps  : {len(d['steps'])}")
    for s in d["steps"]:
        for a in s["actions"]:
            print(f"      - {s['name']!r} / {a['name']!r}")
            print(f"          type={a['type']} script={a['script_file']} pkg={a['package']} envs={a['envs'] or 'ALL'}")
    print(f"  variables         : {d['variable_count']}")
    for env, names in d["variables_by_env"].items():
        print(f"      [{env}] {len(names)}")
        for n in names[:40]:
            print(f"          {n}")
        if len(names) > 40:
            print(f"          ... +{len(names) - 40} more")
    print()

if "error" not in ref and "error" not in tgt:
    print("=" * 78)
    print("GAP — present in reference, missing in target")
    print("=" * 78)
    ref_names = {n for names in ref["variables_by_env"].values() for n in names}
    tgt_names = {n for names in tgt["variables_by_env"].values() for n in names}
    missing = sorted(ref_names - tgt_names)
    print(f"  variables missing : {len(missing)}")
    for n in missing:
        print(f"      {n}")
    print(f"  target steps      : {len(tgt['steps'])} (reference has {len(ref['steps'])})")
    if not tgt["steps"]:
        print("      ^^ NO DEPLOYMENT PROCESS - the project cannot deploy anything.")
    tgt_envs = {e for ph in tgt["lifecycle_phases"] for e in ph["environments"]}
    if "qa" not in {e.lower() for e in tgt_envs}:
        print("      ^^ lifecycle has NO qa phase - cannot deploy to qa even once configured.")

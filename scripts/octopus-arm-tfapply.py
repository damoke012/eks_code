#!/usr/bin/env python3
"""Arm or disarm TfApply for one environment, and refresh the release snapshot with it.

TfApply=false means the deploy plans and stops. Arming it is the one action in this
sequence that changes real infrastructure, so it is deliberately its own step, scoped to
one environment, and undone by --disarm.

Two traps this handles, both of which have already cost a run:
  - a release freezes its variables, so arming the project without re-snapshotting the
    release leaves the deploy running TfApply=false while the project reads true;
  - leaving TfApply armed means the NEXT deploy to that environment applies with nobody
    deciding to. --disarm removes the scoped variable entirely.

    python3 scripts/octopus-arm-tfapply.py iaac-risingwave-onprem production 0.5.6 --arm
    python3 scripts/octopus-arm-tfapply.py iaac-risingwave-onprem production 0.5.6 --arm --apply
    python3 scripts/octopus-arm-tfapply.py iaac-risingwave-onprem production 0.5.6 --disarm --apply
"""
import json, os, sys, time, urllib.error, urllib.request
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


if len(sys.argv) < 4 or not ({"--arm", "--disarm"} & set(sys.argv)):
    sys.exit(__doc__)
project_slug, env_name, version = sys.argv[1], sys.argv[2], sys.argv[3]
arm = "--arm" in sys.argv
apply = "--apply" in sys.argv
if arm and "--disarm" in sys.argv:
    sys.exit("ERROR: pass --arm or --disarm, not both.")

project = api("GET", f"/api/{SPACE_ID}/projects/{project_slug}")
release = api("GET", f"/api/{SPACE_ID}/projects/{project['Id']}/releases/{version}")
envs = {e["Name"].lower(): e for e in api("GET", f"/api/{SPACE_ID}/environments?take=200")["Items"]}
env = envs.get(env_name.lower())
if not env:
    sys.exit(f"ERROR: environment {env_name!r} not found")
env_id = env["Id"]
print(f"Project {project['Id']}  Release {release['Id']} v{release['Version']}  Env {env_id} ({env['Name']})")

varset_id = project["VariableSetId"]
varset = api("GET", f"/api/{SPACE_ID}/variables/{varset_id}")
existing = varset.get("Variables", [])
scoped = [v for v in existing
          if v["Name"] == "TfApply" and env_id in ((v.get("Scope") or {}).get("Environment") or [])]
others = [v for v in existing
          if v["Name"] == "TfApply" and env_id not in ((v.get("Scope") or {}).get("Environment") or [])]
for v in others:
    sc = (v.get("Scope") or {}).get("Environment") or []
    print(f"  other TfApply: {v.get('Value')!r} scoped {sc or '(unscoped)'} — unchanged")
print(f"  {env['Name']}-scoped TfApply now: "
      + (repr(scoped[0].get('Value')) if scoped else "absent (deploys are plan-only)"))

if arm:
    if scoped and scoped[0].get("Value") == "true":
        print("\nAlready armed.")
        new_vars = existing
    else:
        print(f"\n  ARM  TfApply = true, scoped to {env['Name']} only")
        new_vars = [v for v in existing if v not in scoped] + [{
            "Id": "", "Name": "TfApply", "Value": "true",
            "Description": f"Armed for one {env['Name']} apply (INFRA-1674). Remove after.",
            "Scope": {"Environment": [env_id]},
            "IsEditable": True, "IsSensitive": False, "Prompt": None, "Type": "String",
        }]
else:
    if not scoped:
        print("\nAlready disarmed — nothing scoped to this environment.")
        new_vars = existing
    else:
        print(f"\n  DISARM  removing the {env['Name']}-scoped TfApply entirely")
        new_vars = [v for v in existing if v not in scoped]

if not apply:
    print("\nDry run. Pass --apply to write, then this refreshes the release snapshot too.")
    sys.exit(0)

ts = time.strftime("%Y%m%dT%H%M%S")
backup = Path(f"/tmp/octopus-tfapply-backup-{ts}.json")
backup.write_text(json.dumps(varset, indent=2))
print(f"Backup: {backup}")

varset["Variables"] = new_vars
api("PUT", f"/api/{SPACE_ID}/variables/{varset_id}", varset)

# Verify by VALUE on the project, then push it into the release's frozen snapshot —
# a release deploys its snapshot, not the project.
after = api("GET", f"/api/{SPACE_ID}/variables/{varset_id}")
now = [v for v in after.get("Variables", [])
       if v["Name"] == "TfApply" and env_id in ((v.get("Scope") or {}).get("Environment") or [])]
got = now[0].get("Value") if now else None
want = "true" if arm else None
if got != want:
    sys.exit(f"ABORT: project read-back is {got!r}, expected {want!r}.")
print(f"Project verified: {env['Name']}-scoped TfApply = {got!r}")

before_snap = release["ProjectVariableSetSnapshotId"]
api("POST", f"/api/{SPACE_ID}/releases/{release['Id']}/snapshot-variables")
rel2 = api("GET", f"/api/{SPACE_ID}/releases/{release['Id']}")
after_snap = rel2["ProjectVariableSetSnapshotId"]
if before_snap == after_snap:
    sys.exit("ABORT: the release still points at the same variable snapshot — it would "
             "deploy the OLD TfApply. Nothing is armed for this release.")
snap = api("GET", f"/api/{SPACE_ID}/variables/{after_snap}")
snap_val = next((v.get("Value") for v in snap.get("Variables", [])
                 if v["Name"] == "TfApply"
                 and env_id in ((v.get("Scope") or {}).get("Environment") or [])), None)
print(f"Snapshot {before_snap} -> {after_snap}; frozen TfApply = {snap_val!r}")
if snap_val != want:
    sys.exit(f"ABORT: the refreshed snapshot holds {snap_val!r}, expected {want!r}.")

if arm:
    print(f"\nARMED. The next deploy of {version} to {env['Name']} APPLIES.")
    print("After it finishes, confirm the terraform_outputs.yml artifact, then disarm:")
    print(f"  python3 scripts/octopus-arm-tfapply.py {project_slug} {env_name} {version} --disarm --apply")
else:
    print(f"\nDISARMED. Deploys of {version} to {env['Name']} are plan-only again.")

#!/usr/bin/env python3
"""Fetch the raw task log for a release's deployment and read the Terraform plan out of it.

A plan-only Octopus deploy reports Success whether the plan is what you wanted or not
(TfApply=false: plan, skip apply, exit 0). "The deployment completed successfully" is a
fact about the step running, not about the plan. So print the parts that decide it:
which backend bucket was used, the plan summary, and every destroy.

    python3 scripts/octopus-task-log.py iaac-risingwave-onprem 0.5.6 production
    python3 scripts/octopus-task-log.py iaac-risingwave-onprem 0.5.6 production --full
"""
import json, os, re, sys, urllib.error, urllib.request
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


def api(method, path, raw=False):
    req = urllib.request.Request(OCTO_URL + path, method=method,
                                 headers={"X-Octopus-ApiKey": KEY, "Accept": "*/*"})
    try:
        with urllib.request.urlopen(req) as r:
            body = r.read()
            if raw:
                return body.decode(errors="replace")
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"ERROR {e.code} on {method} {path}\n{e.read()[:600].decode(errors='replace')}")


if len(sys.argv) < 4:
    sys.exit(__doc__)
project_slug, version, env_name = sys.argv[1], sys.argv[2], sys.argv[3]
full = "--full" in sys.argv

project = api("GET", f"/api/{SPACE_ID}/projects/{project_slug}")
release = api("GET", f"/api/{SPACE_ID}/projects/{project['Id']}/releases/{version}")
envs = {e["Name"].lower(): e["Id"] for e in api("GET", f"/api/{SPACE_ID}/environments?take=200")["Items"]}
env_id = envs.get(env_name.lower())
if not env_id:
    sys.exit(f"ERROR: environment {env_name!r} not found")

deps = [d for d in api("GET", f"/api/{SPACE_ID}/releases/{release['Id']}/deployments?take=100")["Items"]
        if d["EnvironmentId"] == env_id]
if not deps:
    sys.exit(f"ERROR: release {version} has no deployment to {env_name}")
dep = deps[0]  # newest first
task = api("GET", f"/api/{SPACE_ID}/tasks/{dep['TaskId']}")
print(f"Task {task['Id']}  state={task['State']}  {task.get('Description')}")
print(f"Log: {OCTO_URL}/app#/{SPACE_ID}/tasks/{task['Id']}\n")

log = api("GET", f"/api/{SPACE_ID}/tasks/{task['Id']}/raw?tail=100000", raw=True)

if full:
    print(log)
    sys.exit(0)

# The backend actually used. A corrected variable that never reached the release
# snapshot shows up here as the old bucket.
for m in re.finditer(r"terraform init .*", log):
    print("BACKEND:", m.group(0).strip())

# Terraform's own summary line, and every destroy.
summary = re.findall(r"Plan: \d+ to add, \d+ to change, \d+ to destroy\.", log)
destroys = [l.strip() for l in log.splitlines()
            if re.search(r"will be destroyed|must be replaced|# forces replacement", l)]
no_changes = "No changes." in log or "no changes are needed" in log.lower()

print()
if summary:
    for s in summary:
        print("PLAN:", s)
elif no_changes:
    print("PLAN: No changes.")
else:
    print("PLAN: no plan summary line found in the log — the plan may not have run.")
    print("      Re-run with --full and read it.")

if destroys:
    print(f"\nDESTROYS ({len(destroys)}) — STOP, do not arm TfApply:")
    for d in destroys:
        print("  ", d)
else:
    print("\nDESTROYS: none found.")

errs = [l.strip() for l in log.splitlines() if re.search(r"^\s*(Error|Write-Error|Fatal)", l)]
if errs:
    print(f"\nERRORS ({len(errs)}):")
    for e in errs[:20]:
        print("  ", e)

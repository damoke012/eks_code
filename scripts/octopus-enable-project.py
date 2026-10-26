#!/usr/bin/env python3
"""Re-enable a disabled Octopus project. DRY RUN unless --apply.

    python3 scripts/octopus-enable-project.py                 # show, change nothing
    python3 scripts/octopus-enable-project.py --apply
    python3 scripts/octopus-enable-project.py --project X --apply

WHY THIS EXISTS: iaac-talos was found disabled on 2026-10-26, set by
'/IsDisabled -> true' on 2026-10-22T13:00:29 by the 'lazy' account from a CI
runner. While it is disabled, NO release can be created and NO deploy can run,
so every Terraform change to all three on-prem clusters is blocked.

⚠️ TWO THINGS TO KNOW BEFORE RUNNING THIS WITH --apply

1. TfApply is TRUE for production, qa and qa2 on iaac-talos. Enabling the
   project does not deploy anything, but it removes what has been preventing a
   deploy -- and the next production deploy APPLIES FOR REAL.

2. Something disabled it once, by API, from automation. If that something runs
   again it may disable it again. This prints the time of the last IsDisabled
   change so a repeat is recognisable, and re-running this script read-only is
   how you check. Do not assume the enable sticks.

Octopus requires the WHOLE document on PUT, so this reads the live project,
changes exactly one field, and writes it back -- never a hand-built body.

Prereq: `octopus login` (~/.config/octopus/cli_config.json) or OCTOPUS_API_KEY.
"""
import json, os, sys
from pathlib import Path

try:
    import requests
except ImportError:
    sys.exit("NOT MEASURED - requests missing. pip install requests")

OCTO_URL = "https://octopus.usxpress.io"
SPACE_ID = "Spaces-2"
CLI_CONFIG_CANDIDATES = [
    Path.home() / ".config" / "octopus" / "cli_config.json",
    Path.home() / ".octopus" / "cli_config.json",
]


def arg(flag, default):
    return sys.argv[sys.argv.index(flag) + 1] if flag in sys.argv else default


PROJECT_SLUG = arg("--project", "iaac-talos")
APPLY = "--apply" in sys.argv


def load_api_key():
    for c in CLI_CONFIG_CANDIDATES:
        if c.exists():
            cfg = json.loads(c.read_text())
            for k in ("apikey", "ApiKey", "apiKey"):
                if cfg.get(k):
                    return cfg[k]
            for _, hv in (cfg.get("Hosts") or cfg.get("hosts") or {}).items():
                for k in ("ApiKey", "apiKey", "apikey"):
                    if hv.get(k):
                        return hv[k]
    sys.exit("NOT MEASURED - no Octopus API key. Run `octopus login`.")


session = requests.Session()
session.headers.update({
    "X-Octopus-ApiKey": os.environ.get("OCTOPUS_API_KEY") or load_api_key(),
    "Content-Type": "application/json",
    "Accept": "application/json",
})


def get(path):
    r = session.get(f"{OCTO_URL}{path}")
    if not r.ok:
        sys.exit(f"NOT MEASURED - HTTP {r.status_code} on {path}: {r.text[:200]}")
    return r.json()


project = get(f"/api/{SPACE_ID}/projects/{PROJECT_SLUG}")
print(f"project:  {project['Id']}  {project['Name']}")
print(f"disabled: {project.get('IsDisabled')}")

if not project.get("IsDisabled"):
    print("\nAlready enabled. Nothing to do, and nothing was written.")
    sys.exit(0)

# Who disabled it, and when -- printed every run, so a SECOND disable after this
# one is obvious rather than something to re-investigate from scratch.
print("\n-- last IsDisabled change on record")
ev = session.get(f"{OCTO_URL}/api/{SPACE_ID}/events",
                 params={"regarding": project["Id"], "take": 60})
found = False
if ev.ok:
    for item in (ev.json() or {}).get("Items", []):
        if "was modified" not in (item.get("Message") or "").lower():
            continue
        doc = session.get(f"{OCTO_URL}/api/events/{item['Id']}")
        if not doc.ok:
            continue
        d = doc.json()
        for df in ((d.get("ChangeDetails") or {}).get("Differences") or []):
            if "isdisabled" in str(df.get("path", "")).lower():
                print(f"   {d.get('Occurred','?')[:19]}  "
                      f"{d.get('Username','?')}  -> {df.get('value')}")
                print(f"   agent: {str(d.get('UserAgent'))[:90]}")
                print(f"   ip:    {d.get('IpAddress')}")
                found = True
                break
        if found:
            break
if not found:
    print("   NOT MEASURED - no IsDisabled event in the last 60 project events")

if not APPLY:
    print("\nDRY RUN. Nothing was written.")
    print("To enable:  python3 " + os.path.basename(__file__) +
          f" --project {PROJECT_SLUG} --apply")
    sys.exit(0)

print("\n⚠️  TfApply is TRUE for production on iaac-talos. Enabling does not")
print("    deploy, but the next production deploy applies for real.")
reply = input("    Type the project name to confirm: ").strip()
if reply != project["Name"]:
    sys.exit("Aborted. Nothing was written.")

project["IsDisabled"] = False
r = session.put(f"{OCTO_URL}/api/{SPACE_ID}/projects/{project['Id']}",
                data=json.dumps(project))
if not r.ok:
    sys.exit(f"FAILED - HTTP {r.status_code}: {r.text[:300]}")

# Read back from the server. The PUT's own response is not the stored state.
after = get(f"/api/{SPACE_ID}/projects/{PROJECT_SLUG}")
print(f"\nread-back disabled: {after.get('IsDisabled')}")
if after.get("IsDisabled"):
    sys.exit("STILL DISABLED after a successful PUT - something re-applied it.")
print("ENABLED. Releases can be created and deploys can run again.")
print("\nRe-run this script read-only in a day. If it reports disabled again,")
print("the automation that set it on 2026-10-22 is still running.")

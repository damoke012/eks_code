#!/usr/bin/env python3
"""Dump the Octopus variables that actually build the on-prem clusters.

Why: deploy.ps1 reads no tfvars -- every value comes from Octopus TF_VAR_* parameters. The
seven vSphere placement values that a new environment needs (gap A4) exist ONLY here. This
prints them, with the environment each is scoped to, so they can be moved into git.

Sensitive variables come back from the API with a null value, so nothing secret is printed.

    python3 scripts/octopus-dump-talos-vars.py            # prompts for the key
    python3 scripts/octopus-dump-talos-vars.py --all      # every project
"""
import json, os, pathlib, sys, urllib.error, urllib.request

BASE = os.environ.get("OCTOPUS_URL", "https://octopus.usxpress.io").rstrip("/") + "/api"
KEY = os.environ.get("OCTOPUS_API_KEY", "")
MATCH = None if "--all" in sys.argv else "talos"

# Three sources, in order: env var, a 0600 key file, then an interactive prompt.
# The prompt is last because hidden input through a pasted terminal session is unreliable --
# it silently produced an empty key twice on 2026-09-17.
KEYFILE = pathlib.Path.home() / ".octopus-api-key"
if not KEY and KEYFILE.exists():
    KEY = KEYFILE.read_text().strip()
    print(f"using key from {KEYFILE}")
if not KEY:
    import getpass
    try:
        KEY = getpass.getpass("Octopus API key (hidden, starts with API-): ").strip()
    except (EOFError, KeyboardInterrupt):
        sys.exit("\n!! no key entered")
if not KEY:
    sys.exit("!! no key received -- nothing was typed, or the paste did not land.\n"
             "   Write it to a file instead:\n"
             "     read -rs -p 'paste key: ' K && printf '%s' \"$K\" > ~/.octopus-api-key"
             " && chmod 600 ~/.octopus-api-key && unset K")
if not KEY.startswith("API-"):
    sys.exit("!! that does not look like an Octopus API key -- it must start with 'API-'.\n"
             "   Octopus profile -> My API Keys -> New API Key. Nothing was sent.")

def get(path):
    req = urllib.request.Request(BASE + path, headers={"X-Octopus-ApiKey": KEY})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:300]
        # 401 is about the KEY, 403 about permissions, 404 about the path. Different asks.
        sys.exit(f"!! HTTP {e.code} on {path}\n   {body}\n"
                 + ("   The key is rejected or expired -- ask an Octopus admin.\n"
                    if e.code == 401 else ""))
    except Exception as e:
        sys.exit(f"!! cannot reach {BASE} -- this says nothing about the data.\n   {e}")

spaces = get("/spaces/all")
if not isinstance(spaces, list):
    sys.exit("!! /spaces/all did not return a list:\n" + json.dumps(spaces)[:300])
print("SPACES: " + ", ".join(f'{s["Id"]}={s["Name"]}' for s in spaces))

PLACEMENT = {"datacenter", "datastore", "vm_cluster_name", "vm_folder", "network_name",
             "content_library_name", "content_library_item_name"}
found_placement = set()

for sp in spaces:
    sid = sp["Id"]
    try:
        envs = {e["Id"]: e["Name"] for e in get(f"/{sid}/environments/all")}
        projects = get(f"/{sid}/projects/all")
    except SystemExit:
        raise
    except Exception as e:
        print(f'\n  {sp["Name"]}: cannot enumerate ({e})')
        continue

    for p in projects:
        if MATCH and MATCH not in p["Name"].lower():
            continue
        print(f'\n=== {sp["Name"]} / {p["Name"]}  ({p["Id"]}) ===')

        sets = [("project", p.get("VariableSetId"))]
        for lib in p.get("IncludedLibraryVariableSetIds", []):
            try:
                sets.append(("library:" + get(f"/{sid}/libraryvariablesets/{lib}")["Name"],
                             get(f"/{sid}/libraryvariablesets/{lib}")["VariableSetId"]))
            except Exception as e:
                print(f"  (cannot read library set {lib}: {e})")

        for origin, vsid in sets:
            if not vsid:
                continue
            try:
                vs = get(f"/{sid}/variables/{vsid}")
            except Exception as e:
                print(f"  (cannot read {origin} variables: {e})")
                continue
            rows = vs.get("Variables", [])
            if not rows:
                print(f"  [{origin}] no variables")
                continue
            print(f"  [{origin}] {len(rows)} variable(s)")
            for v in sorted(rows, key=lambda r: r["Name"]):
                scope_ids = v.get("Scope", {}).get("Environment", []) or []
                scope = ",".join(envs.get(i, i) for i in scope_ids) or "ALL"
                val = "<sensitive>" if v.get("IsSensitive") else v.get("Value")
                val = "" if val is None else str(val)
                short = v["Name"].replace("TF_VAR_", "")
                if short in PLACEMENT:
                    found_placement.add(short)
                    mark = " <-- A4"
                else:
                    mark = ""
                print(f'    {v["Name"]:<42} = {val[:58]:<58} [{scope}]{mark}')

print("\n--- gap A4: vSphere placement ---")
missing = PLACEMENT - found_placement
if found_placement:
    print("found in Octopus: " + ", ".join(sorted(found_placement)))
if missing:
    print("NOT FOUND anywhere above: " + ", ".join(sorted(missing)))
    print("An empty result here is not proof they do not exist -- check the scope filter and")
    print("whether this key can read every space before concluding.")

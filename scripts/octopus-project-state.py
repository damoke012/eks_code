#!/usr/bin/env python3
"""Is the iaac-talos Octopus project deployable right now? READ ONLY.

    python3 scripts/octopus-project-state.py
    python3 scripts/octopus-project-state.py --project iaac-risingwave-onprem

WHY THIS EXISTS: on 2026-10-26 the prod SSO cutover reached the release page
and found "This project is currently disabled, so releases cannot be created."
A disabled project blocks a release and its deploy, so the two stages that
carry the change cannot run -- and nothing earlier in the procedure says so.
A pre-flight that fails in five seconds beats discovering it four stages in.

It also prints TfApply per environment, because on this project production is
the ONE environment where a deploy applies for real.

Exit 0 deployable, 1 blocked, 3 not measured. Writes nothing, ever.

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
    sys.exit("NOT MEASURED - no Octopus API key. Run `octopus login` "
             "or set OCTOPUS_API_KEY. This says nothing about the project.")


session = requests.Session()
session.headers.update({
    "X-Octopus-ApiKey": os.environ.get("OCTOPUS_API_KEY") or load_api_key(),
    "Accept": "application/json",
})


def api(path):
    r = session.get(f"{OCTO_URL}{path}")
    if not r.ok:
        sys.exit(f"NOT MEASURED - HTTP {r.status_code} on {path}: {r.text[:200]}")
    return r.json() if r.text else {}


project = api(f"/api/{SPACE_ID}/projects/{PROJECT_SLUG}")
disabled = bool(project.get("IsDisabled"))
print(f"project:  {project['Id']}  {project['Name']}")
print(f"disabled: {disabled}")

envs = {e["Id"]: e["Name"] for e in api(f"/api/{SPACE_ID}/environments?take=200")["Items"]}
varset = api(f"/api/{SPACE_ID}/variables/{project['VariableSetId']}")

# TfApply decides whether a deploy applies or only prints a plan, and it is the
# difference between a rehearsal and a production change. Print it per scope.
print("TfApply:")
found = False
for v in varset.get("Variables", []):
    if v["Name"] != "TfApply":
        continue
    found = True
    scope = [envs.get(i, i) for i in (v.get("Scope") or {}).get("Environment", [])]
    print(f"   {v.get('Value')!r:8} scope={scope or '(all)'}")
if not found:
    print("   not defined on this project")

rel = api(f"/api/{SPACE_ID}/projects/{project['Id']}/releases?take=1")
items = rel.get("Items") or []
if items:
    print(f"latest release: {items[0]['Version']}  assembled {items[0].get('Assembled','?')}")
else:
    print("latest release: none")

# --- who changed what, and when ----------------------------------------------
# A disabled project is a DECISION with an author. The audit log is the only
# place that records it, and the same trail dates the variable, which decides
# whether "the variable was never scoped to production" was ever true.
EVENTS = int(arg("--events", "0"))
# Only fetch diffs when asked: it is one extra request per modified event.
DETAIL = "--detail" in sys.argv
if EVENTS:
    users = {}

    def whom(ev):
        n = ev.get("Username") or ev.get("UserName")
        if n:
            return n
        uid = ev.get("UserId")
        if not uid:
            return "?"
        if uid not in users:
            try:
                users[uid] = api(f"/api/users/{uid}").get("DisplayName", uid)
            except SystemExit:
                users[uid] = uid
        return users[uid]

    # The parameter name for "events about this document" has changed across
    # Octopus versions. Try each and SAY which one answered, so an empty result
    # is distinguishable from a query the server ignored.
    for doc, label in ((project["Id"], "project"),
                       (project["VariableSetId"], "variable set")):
        print(f"\n-- audit trail for the {label} ({doc})")
        got = None
        for param in ("regarding", "documents", "regardingAny"):
            try:
                r = session.get(f"{OCTO_URL}/api/{SPACE_ID}/events",
                                params={param: doc, "take": EVENTS})
            except Exception as e:
                print(f"   {param}: request failed: {e}")
                continue
            if not r.ok:
                print(f"   {param}: HTTP {r.status_code}")
                continue
            items = (r.json() or {}).get("Items", [])
            print(f"   {param}: HTTP 200, {len(items)} events")
            if items:
                got = items
                break
        if got is None:
            print("   NOT MEASURED - no parameter spelling returned events.")
            print("   This is the API, not the history: read the audit log in the UI.")
            continue
        for ev in got:
            msg = " ".join((ev.get("Message") or "").split())
            print(f"   {ev.get('Occurred','?')[:19]}  {whom(ev):22.22}  {msg[:110]}")
            # "Project X was modified" does not say WHAT changed, and that is
            # the whole question when a project turns up disabled. Pull the
            # diff for those, and only those.
            if not DETAIL or "was modified" not in msg.lower():
                continue
            eid = ev.get("Id")
            shown = False
            # First ask the event itself what it carries. Guessing endpoint
            # spellings produced four NOT MEASUREDs; printing the document's
            # own keys says what exists instead of what we hoped for.
            if "--raw" in sys.argv:
                for path in (f"/api/{SPACE_ID}/events/{eid}", f"/api/events/{eid}"):
                    try:
                        r0 = session.get(f"{OCTO_URL}{path}")
                    except Exception:
                        continue
                    if not r0.ok:
                        continue
                    doc0 = r0.json() or {}
                    print(f"        keys: {sorted(doc0.keys())}")
                    cd = doc0.get("ChangeDetails") or {}
                    if cd:
                        print(f"        ChangeDetails keys: {sorted(cd.keys())}")
                        for df in (cd.get("Differences") or [])[:12]:
                            print(f"          {df}")
                        shown = True
                    break
            if shown:
                continue
            for path in (f"/api/{SPACE_ID}/events/{eid}/details",
                         f"/api/events/{eid}/details"):
                try:
                    r2 = session.get(f"{OCTO_URL}{path}")
                except Exception:
                    continue
                if not r2.ok:
                    continue
                d = r2.json() or {}
                diffs = (d.get("ChangeDetails") or {}).get("Differences") or []
                if not diffs:
                    txt = json.dumps(d)[:400]
                    print(f"        detail: {txt}")
                    shown = True
                    break
                for df in diffs[:12]:
                    print(f"        {df.get('Name','?')}: "
                          f"{str(df.get('OldValue'))[:40]!r} -> "
                          f"{str(df.get('NewValue'))[:40]!r}")
                shown = True
                break
            if not shown:
                print("        detail: NOT MEASURED - no detail endpoint answered")

print()
if disabled:
    print("BLOCKED - the project is DISABLED. No release can be created and no")
    print("  deploy can run, so the Octopus half of this change cannot proceed.")
    print("  Find out WHY before re-enabling: with TfApply true for production,")
    print("  disabling the project is a plausible deliberate safety catch, and")
    print("  re-enabling it makes every future prod deploy live again.")
    sys.exit(1)
print("DEPLOYABLE - the project is enabled.")
sys.exit(0)

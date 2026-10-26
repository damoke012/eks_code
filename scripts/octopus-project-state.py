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
SCAN = int(arg("--scan-disables", "0"))


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

# What is actually deployed where. The Releases page lists what EXISTS; this is
# what each environment is RUNNING, which is the only safe basis for choosing a
# release to redeploy with refreshed variables.
prog = api(f"/api/{SPACE_ID}/progression/{project['Id']}")
envnames = {e["Id"]: e["Name"] for e in (prog.get("Environments") or [])}
print("deployed now:")
latest_per_env = {}
for item in (prog.get("Releases") or []):
    ver = (item.get("Release") or {}).get("Version", "?")
    for env_id, deps in (item.get("Deployments") or {}).items():
        for d in deps:
            key = envnames.get(env_id, env_id)
            when = d.get("Created", "")[:19]
            if key not in latest_per_env or when > latest_per_env[key][1]:
                latest_per_env[key] = (ver, when, d.get("State", "?"))
if latest_per_env:
    for env in sorted(latest_per_env):
        ver, when, st = latest_per_env[env]
        print(f"   {env:16.16} {ver:44.44} {when}  {st}")
else:
    print("   NOT MEASURED - progression returned no deployments")

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
        # Free: the list response is already here. Print what an event actually
        # carries, and its Links, rather than guessing another URL -- four
        # spellings were guessed before this and all four returned NOT MEASURED.
        if got:
            print(f"   event fields: {sorted(got[0].keys())}")
            lk = got[0].get("Links") or {}
            if lk:
                print(f"   event links:  {lk}")
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
                        print(f"        raw {path}: HTTP {r0.status_code}")
                        continue
                    doc0 = r0.json() or {}
                    print(f"        keys: {sorted(doc0.keys())}")
                    # Who is not enough: a service account is a credential, not
                    # an actor. The caller's fingerprint says WHAT used it.
                    print(f"        service={doc0.get('IsService')} "
                          f"ip={doc0.get('IpAddress')} "
                          f"auth={doc0.get('IdentityEstablishedWith')}")
                    print(f"        agent={str(doc0.get('UserAgent'))[:120]}")
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

# --- is this project special, or is something disabling projects generally? --
# One project disabled is a decision about that project. Twenty is a hygiene
# job, and the difference decides whether to argue the case or just opt out.
if SCAN:
    print(f"\n== scanning the last {SCAN} project events for IsDisabled changes")
    # ⚠️ The LIST response has a ChangeDetails key but does not populate it --
    # the diff only arrives when an event is fetched BY ID. A first version read
    # it off the list items and reported "no IsDisabled changes" across 300
    # events, including the one we had already seen with our own eyes. A check
    # that cannot detect the case we know about is not a check.
    # 400 events covered 7.5 hours on 2026-10-26: this space does ~1300 project
    # events a day, so walking back four days by `take` alone is thousands of
    # rows. Ask the server for a date window instead -- and then CHECK that it
    # honoured it, because an ignored filter returns today's rows and looks
    # exactly like "nothing happened back then".
    FROM, TO = arg("--from", ""), arg("--to", "")
    params = {"take": SCAN, "documentTypes": "Projects"}
    if FROM:
        params["from"] = f"{FROM}T00:00:00.000Z"
    if TO:
        params["to"] = f"{TO}T23:59:59.000Z"
    r = session.get(f"{OCTO_URL}/api/{SPACE_ID}/events", params=params)
    if not r.ok:
        print(f"   NOT MEASURED - HTTP {r.status_code}")
    else:
        items = (r.json() or {}).get("Items", [])
        if not items:
            print("   NOT MEASURED - the query returned nothing; not a history")
        else:
            occ = [i.get("Occurred", "")[:19] for i in items if i.get("Occurred")]
            print(f"   {len(items)} events, {min(occ)} .. {max(occ)}")
            if FROM and min(occ)[:10] > FROM:
                print(f"   ⚠️  asked from {FROM} but the oldest row is {min(occ)[:10]}.")
                print("      Either the filter was ignored, or take is too small.")
                print("      Raise --scan-disables before reading anything below.")
            mods = [i for i in items
                    if "was modified" in (i.get("Message") or "").lower()]
            cap = min(len(mods), 150)
            print(f"   {len(mods)} 'was modified'; fetching the diff for {cap}")
            rows, control = [], False
            for ev in mods[:cap]:
                rr = session.get(f"{OCTO_URL}/api/events/{ev.get('Id')}")
                if not rr.ok:
                    continue
                doc = rr.json() or {}
                for df in ((doc.get("ChangeDetails") or {}).get("Differences") or []):
                    if "isdisabled" not in str(df.get("path", "")).lower():
                        continue
                    when = doc.get("Occurred", "?")[:19]
                    who = doc.get("Username") or doc.get("UserId") or "?"
                    msg = " ".join((doc.get("Message") or "").split())
                    rows.append((when, who, msg[:58], df.get("value")))
                    if when.startswith("2026-10-22T13:00"):
                        control = True
            # The control: the iaac-talos disable is a known event. If the window
            # covers it and we did not find it, the method is wrong, not the data.
            covered = min(occ) <= "2026-10-22T13:00:29" <= max(occ)
            if covered and not control:
                print("   ⛔ CONTROL FAILED - the window covers 2026-10-22T13:00:29")
                print("      and this did not find it. Do not trust the list below.")
            elif not covered:
                print("   (window does not reach 2026-10-22; raise --scan-disables)")
            else:
                print("   control OK - it found the known iaac-talos disable")
            if rows:
                print(f"   {len(rows)} IsDisabled change(s):")
                for when, who, msg, val in sorted(rows):
                    print(f"   {when}  {who:20.20} -> {val}   {msg}")
            else:
                print("   no IsDisabled change found in the window above")

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

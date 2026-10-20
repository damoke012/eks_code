#!/usr/bin/env python3
"""Inventory one Octopus project's variables as an onboarding classification sheet.

Why this exists: an app being lifted on-prem has to declare every variable it reads,
tagged sensitive or non-sensitive, before anything can be built for it. Asking the app
team to hand-type that list produced "all of ours should be in Octopus" and "we do have
some SQL passwords in sensitive variables, I'm not sure if DX provisions them" in the
same conversation (2026-10-20). Both honest, and they disagree. Read it from the API.

Prints variable NAMES, their environment scope, and whether Octopus marks them sensitive.
A sensitive variable's value comes back null from the API, so nothing secret is printed;
--values additionally prints NON-sensitive values, and refuses to print anything the API
flagged sensitive even if a value is somehow present.

    python3 scripts/octopus-dump-app-vars.py --project pricing
    python3 scripts/octopus-dump-app-vars.py --project pricing --tsv /tmp/pricing.vars.tsv
    python3 scripts/octopus-dump-app-vars.py --self-test     # no network, checks the rules

The --tsv output is a PROPOSAL seeded from Octopus's own sensitive flag, in the format
scripts/app-config-coverage.sh consumes. The application developer approves it; the
platform only proposes (Doke, 2026-10-20). Review every row before using it.
"""
import json, os, pathlib, re, signal, sys, urllib.error, urllib.request

try:
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
except (AttributeError, ValueError):
    pass

# Names that read as a credential. A variable matching one of these while NOT flagged
# sensitive is the finding this script is really for: Octopus prints non-sensitive values
# into the deploy log, so a password in a plain variable is already disclosed.
SECRETISH = re.compile(
    r"(password|passwd|pwd|secret|token|apikey|api_key|accesskey|access_key|"
    r"privatekey|private_key|credential|sasl|clientsecret|client_secret|"
    r"connectionstring|connection_string|conn_?str)", re.I)
# A single variable carrying host, port, database AND password cannot be classified as one
# thing -- split it or the password rides into git inside a value labelled config.
COMPOUND = re.compile(r"(connectionstring|connection_string|conn_?str|_url$|_uri$|_dsn$)", re.I)


def classify(name, is_sensitive):
    """Return (class, flags). Pure, so --self-test can check it without a network."""
    flags = []
    looks_secret = bool(SECRETISH.search(name))
    if is_sensitive:
        cls = "secret"
        if not looks_secret:
            flags.append("SENSITIVE-BUT-UNREMARKABLE-NAME")
    else:
        cls = "config"
        if looks_secret:
            # The important one. Not a style note: it means the value is in plain text in
            # Octopus and in every deploy log that substituted it.
            flags.append("NAMED-LIKE-A-SECRET-NOT-FLAGGED")
    if COMPOUND.search(name):
        flags.append("COMPOUND-SPLIT-IT")
    return cls, flags


SELF_TEST_CASES = [
    ("POSTGRES_PASSWORD", True, "secret", ["" ]),
    ("SQL_PASSWORD", False, "config", ["NAMED-LIKE-A-SECRET-NOT-FLAGGED"]),
    ("KAFKA_BOOTSTRAP_SERVER", False, "config", []),
    ("OTEL_EXPORTER_OTLP_ENDPOINT", False, "config", []),
    ("ENTITY_CONNECTIONSTRING", False, "config",
     ["NAMED-LIKE-A-SECRET-NOT-FLAGGED", "COMPOUND-SPLIT-IT"]),
    ("POSTGRES_ENTITY_URL", True, "secret", ["SENSITIVE-BUT-UNREMARKABLE-NAME", "COMPOUND-SPLIT-IT"]),
    ("KAFKA_SASL_USERNAME", False, "config", ["NAMED-LIKE-A-SECRET-NOT-FLAGGED"]),
]

if "--self-test" in sys.argv:
    bad = 0
    for name, sens, want_cls, want_flags in SELF_TEST_CASES:
        want_flags = [f for f in want_flags if f]
        cls, flags = classify(name, sens)
        if cls != want_cls or flags != want_flags:
            print(f"  FAIL {name}: got ({cls}, {flags}), wanted ({want_cls}, {want_flags})")
            bad += 1
        else:
            print(f"  ok   {name} -> {cls} {flags}")
    print(f"{len(SELF_TEST_CASES) - bad}/{len(SELF_TEST_CASES)} rules passed")
    sys.exit(1 if bad else 0)

# ── arguments ───────────────────────────────────────────────────────────────
def arg(flag, default=None):
    if flag in sys.argv:
        i = sys.argv.index(flag)
        if i + 1 < len(sys.argv) and not sys.argv[i + 1].startswith("--"):
            return sys.argv[i + 1]
        sys.exit(f"!! {flag} needs a value")
    return default

PROJECT = arg("--project")
TSV = arg("--tsv")
SHOW_VALUES = "--values" in sys.argv
if not PROJECT:
    sys.exit("!! --project <name substring> is required. Refusing to dump every project:\n"
             "   a wrong-project inventory looks exactly like a right one.")

BASE = os.environ.get("OCTOPUS_URL", "https://octopus.usxpress.io").rstrip("/") + "/api"
KEY = os.environ.get("OCTOPUS_API_KEY", "")
if KEY and not KEY.startswith("API-"):
    print(f"ignoring OCTOPUS_API_KEY: does not start with 'API-' ({len(KEY)} chars)")
    KEY = ""
KEYFILE = pathlib.Path.home() / ".octopus-api-key"
if not KEY and KEYFILE.exists():
    KEY = KEYFILE.read_text().strip()
    print(f"using key from {KEYFILE}")
if not KEY:
    sys.exit("!! no API key. Write one to a file:\n"
             "   read -rs -p 'paste key: ' K && printf '%s' \"$K\" > ~/.octopus-api-key"
             " && chmod 600 ~/.octopus-api-key && unset K")
if not KEY.startswith("API-"):
    sys.exit("!! that is not an Octopus API key (must start with 'API-'). Nothing was sent.")


def get(path):
    req = urllib.request.Request(BASE + path, headers={"X-Octopus-ApiKey": KEY})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:300]
        hint = {401: "   The key is rejected or expired -- ask an Octopus admin.\n",
                403: "   The key is valid but lacks permission on this space.\n",
                404: "   The path is wrong; this says nothing about the project.\n"}
        sys.exit(f"!! HTTP {e.code} on {path}\n   {body}\n" + hint.get(e.code, ""))
    except Exception as e:
        sys.exit(f"!! cannot reach {BASE} -- NOT MEASURED, says nothing about the data.\n   {e}")


rows_out = []
matched = []
for sp in get("/spaces/all"):
    sid = sp["Id"]
    try:
        envs = {e["Id"]: e["Name"] for e in get(f"/{sid}/environments/all")}
        projects = get(f"/{sid}/projects/all")
    except SystemExit:
        raise
    except Exception as e:
        print(f'  {sp["Name"]}: cannot enumerate ({e})')
        continue

    for p in projects:
        if PROJECT.lower() not in p["Name"].lower():
            continue
        matched.append(f'{sp["Name"]}/{p["Name"]}')
        print(f'\n=== {sp["Name"]} / {p["Name"]}  ({p["Id"]}) ===')

        sets = [("project", p.get("VariableSetId"))]
        for lib in p.get("IncludedLibraryVariableSetIds", []):
            try:
                ls = get(f"/{sid}/libraryvariablesets/{lib}")
                sets.append(("library:" + ls["Name"], ls["VariableSetId"]))
            except Exception as e:
                print(f"  (cannot read library set {lib}: {e})")

        for origin, vsid in sets:
            if not vsid:
                continue
            try:
                vs = get(f"/{sid}/variables/{vsid}")
            except Exception as e:
                print(f"  (cannot read {origin}: {e})")
                continue
            vrows = vs.get("Variables", [])
            print(f"  [{origin}] {len(vrows)} variable(s)")
            for v in sorted(vrows, key=lambda r: r["Name"]):
                name = v["Name"]
                sens = bool(v.get("IsSensitive"))
                scope_ids = v.get("Scope", {}).get("Environment", []) or []
                scope = ",".join(envs.get(i, i) for i in scope_ids) or "ALL"
                cls, flags = classify(name, sens)
                shown = "<sensitive>"
                if not sens:
                    raw = v.get("Value")
                    raw = "" if raw is None else str(raw)
                    shown = (raw if SHOW_VALUES else f"({len(raw)} chars)")
                    if len(shown) > 60:
                        shown = shown[:57] + "..."
                mark = ("  <-- " + " ".join(flags)) if flags else ""
                print(f"    {name:<44} {cls:<7} [{scope}] {shown}{mark}")
                rows_out.append((name, cls, scope, origin, flags))

if not matched:
    print(f"\n!! no project name contains '{PROJECT}'. NOT MEASURED -- an empty result here\n"
          f"   is a bad filter at least as often as an empty project. Re-run with a\n"
          f"   shorter substring, or list projects with octopus-dump-talos-vars.py --all.")
    sys.exit(2)

# ── the findings, restated so they are not lost in the table ───────────────
leaky = sorted({n for n, c, s, o, f in rows_out if "NAMED-LIKE-A-SECRET-NOT-FLAGGED" in f})
compound = sorted({n for n, c, s, o, f in rows_out if "COMPOUND-SPLIT-IT" in f})
inherited = sorted({n for n, c, s, o, f in rows_out if s == "ALL"})
names = {n for n, *_ in rows_out}

print(f"\n--- {len(names)} distinct variable(s) across {len(matched)} project(s): "
      + ", ".join(matched))
print(f"    sensitive per Octopus: {len({n for n, c, *_ in rows_out if c == 'secret'})}")

if leaky:
    print("\n⚠️ NAMED LIKE A CREDENTIAL AND NOT FLAGGED SENSITIVE "
          f"({len(leaky)}) -- these are in plain text in Octopus and in any deploy log\n"
          "   that substituted them. Treat as already disclosed and rotate on the move:")
    for n in leaky:
        print(f"     {n}")
if compound:
    print(f"\n⚠️ COMPOUND VALUES ({len(compound)}) -- one variable carrying host, port, db AND")
    print("   password cannot be classified as one thing. Split before sorting:")
    for n in compound:
        print(f"     {n}")
if inherited:
    print(f"\n⚠️ SCOPED [ALL] ({len(inherited)}) -- no environment overrides these, so a tool")
    print("   that copies what an environment scopes EXPLICITLY will never see them.")
    print("   That is how QA2 planned 13 VMs for a 4-VM cluster. Confirm each deliberately.")

print("\n⚠️ This is the Octopus half only. For a DX-deployed app the OTHER half is whatever")
print("   DX creates in Terraform at deploy time and injects as a Kubernetes secret -- not")
print("   visible here, and not known to the app team. Ask Parul or Rohit.")

if TSV:
    with open(TSV, "w") as fh:
        fh.write("# PROPOSAL seeded from Octopus IsSensitive -- the app developer approves it.\n")
        fh.write(f"# source: {', '.join(matched)}\n")
        fh.write("# Octopus is one of two sources; DX-created secrets are not in here.\n")
        for n, c, s, o, f in sorted(set((n, c, s, o, tuple(f)) for n, c, s, o, f in rows_out)):
            note = ("\t# " + " ".join(f)) if f else ""
            fh.write(f"{n}\t{c}{note}\n")
    print(f"\nwrote {TSV} -- feed it to scripts/app-config-coverage.sh once the\n"
          f"environment is built. Review every row first.")

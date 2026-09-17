#!/usr/bin/env python3
"""Change the value of project variables that are scoped to ONE environment.

Built for a narrow job: correcting a value that was created wrong, without touching any other
environment's copy of the same variable. Only entries whose Scope.Environment is exactly the
named environment are eligible.

    python3 scripts/octopus-set-env-var.py --env qa2 --set TF_VAR_grafana_admin_secret_arn=
    ... --apply

--create adds an entry that does not exist yet. That case is NOT a typo: a value the
environment inherits from [ALL] has no scoped entry to edit. On 2026-09-17 QA2's plan asked
for three control planes because TF_VAR_control_plane_count is [ALL]=3 and nothing had ever
scoped it -- the generator copies only what is scoped to the source, so every inherited value
silently arrives at the [ALL] default. --create prints the inherited value it is overriding.
"""
import argparse, json, os, pathlib, sys, urllib.error, urllib.request

BASE = os.environ.get("OCTOPUS_URL", "https://octopus.usxpress.io").rstrip("/") + "/api"
SPACE = os.environ.get("OCTOPUS_SPACE", "Spaces-2")
PROJECT = os.environ.get("OCTOPUS_PROJECT", "Projects-8283")


def die(m):
    print(f"\n!! {m}\n", file=sys.stderr); sys.exit(1)


def key():
    k = os.environ.get("OCTOPUS_API_KEY", "")
    if k.startswith("API-"):
        return k
    f = pathlib.Path.home() / ".octopus-api-key"
    if f.is_file():
        k = f.read_text().strip()
        if k.startswith("API-"):
            print(f"using key from {f}", file=sys.stderr); return k
    import getpass
    k = getpass.getpass("Octopus API key: ").strip()
    if not k.startswith("API-"):
        die("that does not look like an Octopus API key")
    return k


def call(k, path, method="GET", body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{BASE}{path}", data=data, method=method,
                                 headers={"X-Octopus-ApiKey": k, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read() or "{}")
    except urllib.error.HTTPError as e:
        die(f"{method} {path} -> {e.code}\n{e.read().decode()[:600]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", required=True)
    ap.add_argument("--set", action="append", required=True, metavar="NAME=VALUE",
                    help="repeatable; an empty VALUE clears the variable")
    ap.add_argument("--create", action="store_true",
                    help="create the variable scoped to --env when no entry exists yet, "
                         "instead of refusing. The inherited [ALL] value is printed first.")
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()

    wanted = {}
    for pair in a.set:
        if "=" not in pair:
            die(f"--set expects NAME=VALUE, got {pair!r}")
        n, _, v = pair.partition("=")
        wanted[n] = v

    k = key()
    envs = {e["Name"]: e["Id"] for e in call(k, f"/{SPACE}/environments?take=200")["Items"]}
    if a.env not in envs:
        die(f"environment {a.env!r} not found")
    env_id = envs[a.env]

    doc = call(k, f"/{SPACE}/projects/{PROJECT}/variables")
    backup = pathlib.Path(f"/tmp/octopus-{PROJECT}-setvar-backup.json")
    backup.write_text(json.dumps(doc, indent=2)); backup.chmod(0o600)
    before = len(doc["Variables"])
    print(f"read {before} variables; backed up to {backup}", file=sys.stderr)

    hits = {n: [] for n in wanted}
    for v in doc["Variables"]:
        scope = (v.get("Scope") or {}).get("Environment", [])
        if v["Name"] in wanted and scope == [env_id]:
            hits[v["Name"]].append(v)

    # An entry with an empty Environment scope is the [ALL] fallback -- what this
    # environment resolves to today when nothing is scoped to it.
    inherited = {n: [] for n in wanted}
    for v in doc["Variables"]:
        if v["Name"] in wanted and not (v.get("Scope") or {}).get("Environment"):
            inherited[v["Name"]].append(v)

    to_create = []
    for n, vs in hits.items():
        if len(vs) > 1:
            die(f"{n} has {len(vs)} entries scoped to {a.env} -- resolve by hand")
        if not vs:
            if not a.create:
                cur = repr(inherited[n][0].get("Value")) if inherited[n] else "nothing at all"
                die(f"{n} has no entry scoped exactly to {a.env} -- refusing to guess.\n"
                    f"   It resolves today to the [ALL] value {cur}.\n"
                    f"   Re-run with --create to add an entry scoped to {a.env}.")
            to_create.append(n)

    print(f"\n=== changes for {a.env} ===")
    for n in wanted:
        if n in to_create:
            src = repr(inherited[n][0].get("Value")) if inherited[n] else "nothing at all"
            print(f"  {n}   (NEW -- scoped to {a.env})")
            print(f"      inherited: [ALL] {src}")
            print(f"             to: {wanted[n]!r}")
        else:
            print(f"  {n}")
            print(f"      from: {hits[n][0].get('Value')!r}")
            print(f"        to: {wanted[n]!r}")

    if not a.apply:
        print("\ndry run -- nothing written. Re-run with --apply.")
        return

    for n, vs in hits.items():
        if vs:
            vs[0]["Value"] = wanted[n]
    for n in to_create:
        doc["Variables"].append({
            "Name": n, "Value": wanted[n], "Type": "String",
            "IsSensitive": False, "IsEditable": True, "Prompt": None,
            "Scope": {"Environment": [env_id]},
        })
    call(k, f"/{SPACE}/projects/{PROJECT}/variables", method="PUT", body=doc)

    expected = before + len(to_create)
    after = call(k, f"/{SPACE}/projects/{PROJECT}/variables")
    if len(after["Variables"]) != expected:
        die(f"variable count is {len(after['Variables'])}, expected {expected} "
            f"({before} + {len(to_create)} created) -- restore from {backup}")
    for v in after["Variables"]:
        scope = (v.get("Scope") or {}).get("Environment", [])
        if v["Name"] in wanted and scope == [env_id]:
            got = v.get("Value")
            if got != wanted[v["Name"]]:
                die(f"{v['Name']} is {got!r} after the write, expected {wanted[v['Name']]!r}")
            print(f"  verified {v['Name']} = {got!r}")
    print(f"\nwrote. {before} -> {expected}"
          + (f" ({len(to_create)} created)" if to_create else " (count unchanged)"))


if __name__ == "__main__":
    main()

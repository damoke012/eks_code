#!/usr/bin/env python3
"""Change the value of project variables that are scoped to ONE environment.

Built for a narrow job: correcting a value that was created wrong, without touching any other
environment's copy of the same variable. Only entries whose Scope.Environment is exactly the
named environment are eligible.

    python3 scripts/octopus-set-env-var.py --env qa2 --set TF_VAR_grafana_admin_secret_arn=
    ... --apply
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

    for n, vs in hits.items():
        if not vs:
            die(f"{n} has no entry scoped exactly to {a.env} -- refusing to guess")
        if len(vs) > 1:
            die(f"{n} has {len(vs)} entries scoped to {a.env} -- resolve by hand")

    print(f"\n=== changes for {a.env} ===")
    for n, vs in hits.items():
        old = vs[0].get("Value")
        print(f"  {n}")
        print(f"      from: {old!r}")
        print(f"        to: {wanted[n]!r}")

    if not a.apply:
        print("\ndry run -- nothing written. Re-run with --apply.")
        return

    for n, vs in hits.items():
        vs[0]["Value"] = wanted[n]
    call(k, f"/{SPACE}/projects/{PROJECT}/variables", method="PUT", body=doc)

    after = call(k, f"/{SPACE}/projects/{PROJECT}/variables")
    if len(after["Variables"]) != before:
        die(f"variable count changed {before} -> {len(after['Variables'])} -- restore from {backup}")
    for v in after["Variables"]:
        scope = (v.get("Scope") or {}).get("Environment", [])
        if v["Name"] in wanted and scope == [env_id]:
            got = v.get("Value")
            if got != wanted[v["Name"]]:
                die(f"{v['Name']} is {got!r} after the write, expected {wanted[v['Name']]!r}")
            print(f"  verified {v['Name']} = {got!r}")
    print(f"\nwrote. count unchanged at {before}")


if __name__ == "__main__":
    main()

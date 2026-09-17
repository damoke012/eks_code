#!/usr/bin/env python3
"""Add an environment to an existing lifecycle phase, as an optional (manual) target.

Why not a new phase: phases are sequential, so a phase appended after `production` can only be
reached by deploying to production first. Adding the environment to an existing phase changes no
ordering and no other project's promotion rules.

A lifecycle is shared, so: back up first, add only, refuse if already present, dry-run by default,
and verify afterwards.

    python3 scripts/octopus-add-env-to-phase.py --lifecycle Lifecycles-42 --phase qa --env qa2
    python3 scripts/octopus-add-env-to-phase.py --lifecycle Lifecycles-42 --phase qa --env qa2 --apply
"""
import argparse, json, os, pathlib, sys, urllib.error, urllib.request

BASE = os.environ.get("OCTOPUS_URL", "https://octopus.usxpress.io").rstrip("/") + "/api"
SPACE = os.environ.get("OCTOPUS_SPACE", "Spaces-2")


def die(msg):
    print(f"\n!! {msg}\n", file=sys.stderr)
    sys.exit(1)


def key():
    k = os.environ.get("OCTOPUS_API_KEY", "")
    if k.startswith("API-"):
        return k
    f = pathlib.Path.home() / ".octopus-api-key"
    if f.is_file():
        k = f.read_text().strip()
        if k.startswith("API-"):
            print(f"using key from {f}", file=sys.stderr)
            return k
    import getpass
    k = getpass.getpass("Octopus API key: ").strip()
    if not k.startswith("API-"):
        die("that does not look like an Octopus API key")
    return k


def call(k, path, method="GET", body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{BASE}{path}", data=data, method=method,
                                 headers={"X-Octopus-ApiKey": k,
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read() or "{}")
    except urllib.error.HTTPError as e:
        die(f"{method} {path} -> {e.code}\n{e.read().decode()[:600]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lifecycle", required=True)
    ap.add_argument("--phase", required=True, help="phase NAME, e.g. qa")
    ap.add_argument("--env", required=True, help="environment NAME, e.g. qa2")
    ap.add_argument("--automatic", action="store_true",
                    help="add as an automatic target instead of optional/manual")
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()

    k = key()
    envs = {e["Name"]: e["Id"] for e in call(k, f"/{SPACE}/environments?take=200")["Items"]}
    if a.env not in envs:
        die(f"environment {a.env!r} not found. Have: {', '.join(sorted(envs))}")
    env_id = envs[a.env]
    by_id = {v: n for n, v in envs.items()}

    lc = call(k, f"/{SPACE}/lifecycles/{a.lifecycle}")
    backup = pathlib.Path(f"/tmp/octopus-{a.lifecycle}-backup.json")
    backup.write_text(json.dumps(lc, indent=2))
    backup.chmod(0o600)
    print(f"lifecycle {lc['Name']!r} backed up to {backup}", file=sys.stderr)

    names = [p["Name"] for p in lc["Phases"]]
    target = next((p for p in lc["Phases"] if p["Name"] == a.phase), None)
    if target is None:
        die(f"phase {a.phase!r} not found. Phases: {', '.join(names)}")

    field = "AutomaticDeploymentTargets" if a.automatic else "OptionalDeploymentTargets"
    other = "OptionalDeploymentTargets" if a.automatic else "AutomaticDeploymentTargets"
    if env_id in target.get(field, []) or env_id in target.get(other, []):
        print(f"{a.env} is already a target of phase {a.phase!r} -- nothing to do")
        return

    print(f"\n=== {lc['Name']} ===")
    for p in lc["Phases"]:
        auto = [by_id.get(i, i) for i in p.get("AutomaticDeploymentTargets", [])]
        opt = [by_id.get(i, i) for i in p.get("OptionalDeploymentTargets", [])]
        mark = "   <-- adding here" if p is target else ""
        print(f"  {p['Name']:<14} auto={auto or '-'}  manual={opt or '-'}{mark}")

    print(f"\nwould add {a.env} ({env_id}) to phase {a.phase!r} as "
          f"{'automatic' if a.automatic else 'optional/manual'}")

    if not a.apply:
        print("\ndry run -- nothing written. Re-run with --apply.")
        return

    target.setdefault(field, []).append(env_id)
    call(k, f"/{SPACE}/lifecycles/{a.lifecycle}", method="PUT", body=lc)

    after = call(k, f"/{SPACE}/lifecycles/{a.lifecycle}")
    ph = next((p for p in after["Phases"] if p["Name"] == a.phase), None)
    if ph is None or env_id not in ph.get(field, []):
        die(f"{a.env} is NOT in phase {a.phase!r} after the write -- restore from {backup}")
    if len(after["Phases"]) != len(lc["Phases"]):
        die(f"phase count changed -- restore from {backup}")
    print(f"\nwrote. phase {a.phase!r} targets are now: "
          f"{[by_id.get(i, i) for i in ph.get(field, [])]}")


if __name__ == "__main__":
    main()

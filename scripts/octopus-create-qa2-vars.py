#!/usr/bin/env python3
"""Create the iaac-talos project variables for a NEW environment, derived from an existing one.

Why derived and not typed: every value that differs between environments is a substitution of
the cluster name or the VIP. Transcribing thirty values by hand into a web form is how
`TBD-qa-vip` and a wrong Flux repository name got into the estate in the first place.

SAFETY. The project variable set is a single document -- a PUT replaces all 121 variables.
This script therefore:
  * backs the whole document up to a file before touching anything,
  * only ADDS entries scoped to the new environment, never edits or removes an existing one,
  * refuses if the target environment already has any variable in this project,
  * dry-runs by default and prints exactly what it would add,
  * re-reads and compares the count after writing.

    python3 scripts/octopus-create-qa2-vars.py --from qa --to qa2 --vip 10.10.82.53
    python3 scripts/octopus-create-qa2-vars.py --from qa --to qa2 --vip 10.10.82.53 --apply
"""
import argparse, json, os, pathlib, re, sys, urllib.error, urllib.request

BASE = os.environ.get("OCTOPUS_URL", "https://octopus.usxpress.io").rstrip("/") + "/api"
SPACE = os.environ.get("OCTOPUS_SPACE", "Spaces-2")
PROJECT = os.environ.get("OCTOPUS_PROJECT", "Projects-8283")


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
        die("that does not look like an Octopus API key (they start with API-)")
    return k


def call(k, path, method="GET", body=None):
    url = path if path.startswith("http") else f"{BASE}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"X-Octopus-ApiKey": k,
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read() or "{}")
    except urllib.error.HTTPError as e:
        die(f"{method} {url} -> {e.code}\n{e.read().decode()[:800]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--from", dest="src", required=True, help="environment to copy from, e.g. qa")
    ap.add_argument("--to", dest="dst", required=True, help="new environment name, e.g. qa2")
    ap.add_argument("--vip", required=True, help="control-plane VIP for the new cluster")
    ap.add_argument("--cluster", help="new cluster name (default: <src cluster>-2 style)")
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()

    k = key()

    envs = {e["Name"]: e["Id"] for e in call(k, f"/{SPACE}/environments?take=200")["Items"]}
    if a.src not in envs:
        die(f"source environment {a.src!r} not found. Have: {', '.join(sorted(envs))}")
    if a.dst not in envs:
        die(f"target environment {a.dst!r} does not exist yet.\n"
            f"   Create it first -- merge the iaac-octopus-config PR and let the pipeline apply,\n"
            f"   then re-run. Have: {', '.join(sorted(envs))}")
    src_id, dst_id = envs[a.src], envs[a.dst]
    print(f"{a.src} = {src_id}   ->   {a.dst} = {dst_id}", file=sys.stderr)

    doc = call(k, f"/{SPACE}/projects/{PROJECT}/variables")
    backup = pathlib.Path(f"/tmp/octopus-{PROJECT}-variables-backup.json")
    backup.write_text(json.dumps(doc, indent=2))
    backup.chmod(0o600)
    before = len(doc["Variables"])
    print(f"read {before} variables; full document backed up to {backup}", file=sys.stderr)

    existing_dst = [v for v in doc["Variables"]
                    if dst_id in (v.get("Scope") or {}).get("Environment", [])]
    if existing_dst:
        die(f"{a.dst} already has {len(existing_dst)} variable(s) in this project. "
            "Refusing to add more -- resolve by hand so nothing is duplicated.")

    src_vars = {}
    for v in doc["Variables"]:
        if src_id in (v.get("Scope") or {}).get("Environment", []):
            src_vars.setdefault(v["Name"], v)

    if not src_vars:
        die(f"no variables are scoped to {a.src} -- nothing to derive from")

    # Identifier substitutions. Longest first so op-usxpress-qa does not eat op-qa.
    src_cluster = (src_vars.get("TF_VAR_cluster_name") or {}).get("Value")
    if not src_cluster:
        die(f"{a.src} has no TF_VAR_cluster_name -- cannot derive the new names")
    dst_cluster = a.cluster or f"{src_cluster}-2"

    # talos-cp-op-qa -> talos-cp-op-qa-2 : the short form used in name prefixes
    src_short = src_cluster.replace("op-usxpress-", "op-")
    dst_short = dst_cluster.replace("op-usxpress-", "op-")

    # ONE pass, longest alternative first. Applying these as three sequential str.replace()
    # calls re-scans text the earlier calls produced: op-usxpress-qa -> op-usxpress-qa-2 ->
    # op-usxpress-qa2-2, because the bare "qa" rule then matches inside the new name.
    subs = {src_cluster: dst_cluster, src_short: dst_short, a.src: a.dst}
    _pattern = re.compile("|".join(re.escape(x) for x in
                                   sorted(subs, key=len, reverse=True)))

    def substitute(text):
        return _pattern.sub(lambda m: subs[m.group(0)], text)

    src_vip = (src_vars.get("TF_VAR_control_plane_vip") or {}).get("Value")

    # Values that are NOT a substitution of the source.
    explicit = {
        "TF_VAR_control_plane_vip": a.vip,
        "TF_VAR_endpoint": f"https://{a.vip}:6443",
        "TF_VAR_env_name": a.dst,
        "TF_USE_VARFILE": "true",
        "TfApply": "false",      # source has true for qa -- a new cluster plans first
        "TfDestroy": "false",
    }
    # Never copy these.
    skip = {"TF_VAR_talosconfig_secret_arn"}   # A2 removed the Terraform variable in #67

    # Copy unchanged. An ARN names a resource that ALREADY EXISTS -- substituting the cluster
    # name into one invents an ARN for something nobody created, and the failure surfaces much
    # later as a permissions or not-found error. CLUSTER_NAME is the cloud EKS cluster the
    # worker uses, not this Talos cluster; "qa-one" must not become "qa2-one".
    verbatim = {"CLUSTER_NAME"}

    def is_verbatim(name, value):
        return name in verbatim or value.startswith("arn:")

    additions = []
    for name, v in sorted(src_vars.items()):
        if name in skip:
            print(f"   skip {name} (deliberately not copied)", file=sys.stderr)
            continue
        if v.get("IsSensitive"):
            print(f"   skip {name} (sensitive -- set it by hand)", file=sys.stderr)
            continue
        val = v.get("Value")
        if val is None:
            continue
        if name in explicit:
            new_val = explicit[name]
        elif is_verbatim(name, val):
            new_val = val
            print(f"   verbatim {name} (references an existing resource)", file=sys.stderr)
        else:
            new_val = substitute(val)
            if src_vip and src_vip in new_val:
                new_val = new_val.replace(src_vip, a.vip)
        additions.append({
            "Name": name,
            "Value": new_val,
            "Type": v.get("Type", "String"),
            "IsSensitive": False,
            "IsEditable": v.get("IsEditable", True),
            "Prompt": None,
            "Scope": {"Environment": [dst_id]},
        })

    for name, val in explicit.items():
        if name not in src_vars:
            additions.append({
                "Name": name, "Value": val, "Type": "String",
                "IsSensitive": False, "IsEditable": True, "Prompt": None,
                "Scope": {"Environment": [dst_id]},
            })

    print(f"\n=== {len(additions)} variable(s) to add, scoped to {a.dst} ===")
    for v in additions:
        changed = ""
        s = src_vars.get(v["Name"])
        if s is not None and s.get("Value") != v["Value"]:
            changed = f"   (was: {s['Value'][:44]})"
        print(f"  {v['Name']:<38} = {v['Value'][:52]:<52}{changed}")

    if not a.apply:
        print("\ndry run -- nothing written. Re-run with --apply.")
        return

    doc["Variables"].extend(additions)
    call(k, f"/{SPACE}/projects/{PROJECT}/variables", method="PUT", body=doc)

    after_doc = call(k, f"/{SPACE}/projects/{PROJECT}/variables")
    after = len(after_doc["Variables"])
    print(f"\nwrote. {before} -> {after} variables (expected {before + len(additions)})")
    if after != before + len(additions):
        die(f"count mismatch -- restore from {backup} and investigate")
    still = [v["Name"] for v in after_doc["Variables"]
             if dst_id in (v.get("Scope") or {}).get("Environment", [])]
    print(f"{len(still)} variable(s) now scoped to {a.dst}")


if __name__ == "__main__":
    main()

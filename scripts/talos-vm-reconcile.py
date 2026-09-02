#!/usr/bin/env python3
"""Which Nutanix/vSphere VMs are OURS, and which are not.

Builds the authoritative list of Talos VMs we manage from two independent sources —
the three Terraform state files and the three live clusters — then classifies the rows
of an inventory export (Jon's spreadsheet, saved as CSV) against it.

Why not govc: it is not installed on this workstation (recorded in
wip/prod-standup/preflight-deploy.py). The vSphere inventory therefore comes from the
export; our side comes from state, which is the record that actually decides what
Terraform will keep.

    python3 scripts/talos-vm-reconcile.py                     # print what we manage
    python3 scripts/talos-vm-reconcile.py --diff jon-8-27.csv # classify his inventory

READ-ONLY. It never powers off, deletes or modifies anything, and deliberately emits a
CANDIDATE list rather than a destroy command: a VM absent from state may be unmanaged, or
may be a VM whose state file this run could not read. Those look identical in the output
of a naive script, so this one refuses to classify anything unless every source loaded.

Auth (WSL): aws sso login --profile usx-dev / usx-qa / ops-controller
"""
import argparse
import csv
import json
import re
import subprocess
import sys
from pathlib import Path

REGION = "us-east-2"
SCRIPT_DIR = Path(__file__).resolve().parent

# One entry per cluster. bucket/profile pairs are per-ACCOUNT — a copied backend reads
# nothing, or worse reads another environment's state.
CLUSTERS = [
    {"env": "op-usxpress-dev",  "ctx": "op-dev",  "profile": "usx-dev",
     "bucket": "lazy-tf-state-65v583i6my68y6x9", "key": "iaac/talos/op-usxpress-dev.tfstate",
     "account": "700736442855"},
    {"env": "op-usxpress-qa",   "ctx": "op-qa",   "profile": "usx-qa",
     "bucket": "lazy-tf-state-425rbol87rmn6c7m", "key": "iaac/talos/op-usxpress-qa.tfstate",
     "account": "527101283767"},
    {"env": "op-usxpress-prod", "ctx": "op-prod", "profile": "ops-controller",
     "bucket": "lazy-tf-state-ipp58n854uhpw13x", "key": "iaac/talos/op-usxpress-prod.tfstate",
     "account": "937464026810"},
]


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def preflight(profile, want_account):
    """A dead credential must abort, never contribute an empty VM list."""
    r = run(["aws", "sts", "get-caller-identity", "--profile", profile,
             "--query", "Account", "--output", "text"])
    if r.returncode != 0:
        return None, f"no session for --profile {profile}: {r.stderr.strip().splitlines()[0] if r.stderr else 'unknown'}"
    got = r.stdout.strip()
    if got != want_account:
        return None, f"--profile {profile} lands in {got}, expected {want_account}"
    return got, None


def load_state(c):
    r = run(["aws", "s3", "cp", f"s3://{c['bucket']}/{c['key']}", "-",
             "--profile", c["profile"], "--region", REGION])
    if r.returncode != 0:
        return None, f"cannot read s3://{c['bucket']}/{c['key']}: {r.stderr.strip().splitlines()[-1] if r.stderr else '?'}"
    try:
        return json.loads(r.stdout), None
    except json.JSONDecodeError as e:
        return None, f"state for {c['env']} is not valid JSON: {e}"


def vms_from_state(state):
    """Every vsphere_virtual_machine instance, with the resources it reserves."""
    out = {}
    for res in state.get("resources", []):
        if res.get("type") != "vsphere_virtual_machine":
            continue
        for inst in res.get("instances", []):
            a = inst.get("attributes") or {}
            name = a.get("name")
            if not name:
                continue
            disk_gb = sum((d or {}).get("size", 0) for d in (a.get("disk") or []))
            out[name] = {
                "cpus": a.get("num_cpus"),
                "mem_gb": round((a.get("memory") or 0) / 1024, 1),
                "disk_gb": disk_gb,
                "folder": a.get("folder"),
            }
    return out


def cluster_nodes(ctx):
    """Second, independent source. A node here that is not in state is drift, not an orphan."""
    kubectl = SCRIPT_DIR / "onprem-kubectl.sh"
    if not kubectl.exists():
        return None, "onprem-kubectl.sh not found"
    r = run(["bash", str(kubectl), ctx, "--", "get", "nodes",
             "-o", "jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}"])
    if r.returncode != 0:
        first = (r.stderr or r.stdout).strip().splitlines()
        return None, first[-1] if first else "unreachable"
    return [n for n in r.stdout.split() if n], None


def norm(s):
    return re.sub(r"[^a-z0-9-]", "", (s or "").strip().lower())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--diff", metavar="CSV",
                    help="inventory export to classify (Jon's spreadsheet as CSV)")
    ap.add_argument("--name-column", help="header of the VM-name column, if autodetect picks wrong")
    ap.add_argument("--skip-clusters", action="store_true",
                    help="use Terraform state only (e.g. off VPN)")
    args = ap.parse_args()

    # Two failure classes, deliberately not pooled:
    #   fatal    — a state file did not load. The 'ours' list is then incomplete and
    #              its missing VMs are indistinguishable from unmanaged ones.
    #   degraded — a cluster was unreachable. Classification is unaffected (it reads
    #              state); only the drift check for that cluster is lost.
    # Treating the second as fatal blocked a safe run on 2026-09-02 purely because
    # op-qa was off-VPN, while all three state files had loaded cleanly.
    managed, fatal, degraded, node_only = {}, [], [], {}

    for c in CLUSTERS:
        acct, err = preflight(c["profile"], c["account"])
        if err:
            fatal.append(f"{c['env']}: {err}")
            continue
        state, err = load_state(c)
        if err:
            fatal.append(f"{c['env']}: {err}")
            continue
        vms = vms_from_state(state)
        if not vms:
            fatal.append(f"{c['env']}: state read OK but contains no vsphere_virtual_machine "
                         "— refusing to treat that as 'this cluster owns nothing'")
            continue
        for n, v in vms.items():
            v["env"] = c["env"]
            managed[n] = v
        print(f"  {c['env']:<20} {len(vms):>3} VMs from Terraform state", end="")

        if args.skip_clusters:
            print("   (cluster check skipped)")
            continue
        nodes, nerr = cluster_nodes(c["ctx"])
        if nerr:
            print(f"   (cluster unreachable: {nerr})")
            degraded.append(f"{c['env']}: drift NOT checked — cluster unreachable ({nerr})")
            continue
        extra = [n for n in nodes if n not in vms]
        print(f" · {len(nodes)} nodes live" + (f" · {len(extra)} NOT in state" if extra else ""))
        for n in extra:
            node_only[n] = c["env"]

    # An incomplete OWNERSHIP picture cannot safely say what is unmanaged. Stop here.
    if fatal:
        print("\n!! INCOMPLETE — Terraform state did not load for every cluster:\n")
        for e in fatal:
            print(f"   {e}")
        print("\n   Refusing to classify. A VM missing from a state file this run could not\n"
              "   read is indistinguishable from a VM nobody manages, and the two have very\n"
              "   different consequences. Fix the sources above and re-run.")
        sys.exit(3)

    # A missing cluster costs us the drift check for that cluster and nothing else.
    if degraded:
        print("\n   PARTIAL — ownership is complete, drift checking is not:")
        for e in degraded:
            print(f"     {e}")
        print("     A VM that is in one of these clusters but not in its Terraform state\n"
              "     would not be reported below. That is drift, not an orphan, and it is the\n"
              "     one thing this run cannot see. Re-run on the VPN before acting on drift.")

    tc = sum(v["cpus"] or 0 for v in managed.values())
    tm = sum(v["mem_gb"] or 0 for v in managed.values())
    td = sum(v["disk_gb"] or 0 for v in managed.values())

    # Per-environment subtotals: the capacity conversation is held per environment, and
    # "QA is sized like production" is only checkable if the two are shown side by side.
    print("\n  Per environment, from state:")
    for c in CLUSTERS:
        vs = [v for v in managed.values() if v["env"] == c["env"]]
        if not vs:
            continue
        print(f"    {c['env']:<20} {len(vs):>3} VMs  "
              f"{sum(v['cpus'] or 0 for v in vs):>4} vCPU  "
              f"{sum(v['mem_gb'] or 0 for v in vs):>7.0f} GB RAM  "
              f"{sum(v['disk_gb'] or 0 for v in vs)/1024:>6.2f} TB reserved")
    print(f"\n  OURS: {len(managed)} VMs · {tc} vCPU · {tm:.0f} GB RAM · {td/1024:.2f} TB disk reserved")
    if node_only:
        print(f"\n  In a cluster but NOT in Terraform state ({len(node_only)}) — drift, do NOT delete:")
        for n, e in sorted(node_only.items()):
            print(f"    {n}  ({e})")

    if not args.diff:
        print("\n  Managed VM names:")
        for n in sorted(managed):
            v = managed[n]
            print(f"    {n:<34} {v['env']:<18} {v['cpus']:>3} vCPU  {v['mem_gb']:>6.1f} GB  {v['disk_gb']:>5} GB")
        print("\n  Pass --diff <inventory.csv> to classify an export against this list.")
        return

    path = Path(args.diff)
    if not path.exists():
        sys.exit(f"!! no such file: {path}")
    rows = list(csv.DictReader(path.open(newline="", encoding="utf-8-sig")))
    if not rows:
        sys.exit(f"!! {path} has no data rows")

    cols = list(rows[0].keys())
    col = args.name_column
    if not col:
        for cand in cols:
            if cand and re.search(r"\b(vm|name|guest|machine)\b", cand, re.I):
                col = cand
                break
    if not col:
        sys.exit(f"!! cannot find a VM-name column in {cols}. Pass --name-column.")
    # Say which column was used: a silently wrong column classifies everything as unmanaged.
    print(f"\n  Inventory: {path.name} · {len(rows)} rows · name column = {col!r}")

    managed_norm = {norm(n): n for n in managed}
    ours, theirs = [], []
    for r in rows:
        raw = (r.get(col) or "").strip()
        if not raw:
            continue
        (ours if norm(raw) in managed_norm else theirs).append((raw, r))

    seen = {norm(x[0]) for x in ours}
    missing = [n for k, n in managed_norm.items() if k not in seen]

    print(f"\n== OURS — in Terraform state ({len(ours)})")
    for raw, _ in sorted(ours):
        v = managed[managed_norm[norm(raw)]]
        print(f"   {raw:<34} {v['env']}")

    print(f"\n== NOT OURS — in the inventory, in no Talos state file ({len(theirs)})")
    print("   Candidates for removal. Confirm each with its owner before anything is")
    print("   powered off — 'not in our Terraform' is not the same as 'nobody's'.")
    for raw, r in sorted(theirs):
        extras = [f"{k}={v}" for k, v in r.items() if k != col and v and len(str(v)) < 24][:4]
        print(f"   {raw:<34} {'  '.join(extras)}")

    if missing:
        print(f"\n== IN STATE, NOT IN THE INVENTORY ({len(missing)})")
        print("   Terraform believes it owns these and the export does not list them.")
        print("   Either the export is filtered, or Terraform is tracking VMs that are gone.")
        for n in sorted(missing):
            print(f"   {n:<34} {managed[n]['env']}")

    if theirs:
        print(f"\n  Reclaiming all {len(theirs)} would need each one's owner to agree first.")
    print("\n  Nothing was changed. This script only reads.")


if __name__ == "__main__":
    print("Talos VM reconciliation — read-only\n")
    main()

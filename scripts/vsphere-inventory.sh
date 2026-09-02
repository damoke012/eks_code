#!/usr/bin/env bash
# Dump the vSphere VM inventory to CSV, so we can answer "what is actually on there"
# ourselves instead of waiting for an export.
#
# READ-ONLY BY CONSTRUCTION. It calls only `govc about`, `govc find`, `govc vm.info` and
# `govc datastore.info`. There is no power-off, no destroy, no reconfigure verb anywhere
# in this file, and there should never be one — this is the inventory side of a comparison
# whose other side decides what gets deleted.
#
#   bash scripts/vsphere-inventory.sh                      # all VMs -> stdout summary
#   bash scripts/vsphere-inventory.sh --csv ~/vsphere.csv  # write CSV for the reconciler
#   bash scripts/vsphere-inventory.sh --folder /KubernetesD1/TalosD1
#
# Then:
#   python3 scripts/talos-vm-reconcile.py --diff ~/vsphere.csv
#
# Setup (once):
#   1. govc is a single static binary, no admin rights needed:
#        mkdir -p ~/.local/bin
#        curl -sSL https://github.com/vmware/govmomi/releases/latest/download/govc_Linux_x86_64.tar.gz \
#          | tar -C ~/.local/bin -xzf - govc
#        export PATH="$HOME/.local/bin:$PATH"
#   2. Point it at vCenter and log in AS YOURSELF. Do not reuse the Terraform service
#      account: its password is a sensitive Octopus variable that cannot be read back, and
#      an inventory read does not need it.
#        export GOVC_URL='https://<vcenter-fqdn>'
#        export GOVC_USERNAME='...'
#        export GOVC_PASSWORD='...'
#        export GOVC_INSECURE=1          # only if vCenter uses an internal CA
#
#   The vCenter FQDN is an unscoped Octopus variable on iaac-talos. To find it:
#        python3 scripts/octopus-project-state.py iaac-talos | grep -i -E 'vsphere|vcenter'
set -uo pipefail

FOLDER=""
CSV=""
while [ $# -gt 0 ]; do
  case "$1" in
    --folder) FOLDER="${2:-}"; shift 2 ;;
    --csv)    CSV="${2:-}";    shift 2 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "!! unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v govc >/dev/null 2>&1 || {
  echo "!! govc is not on PATH. Install it (no admin rights needed):" >&2
  echo "     mkdir -p ~/.local/bin" >&2
  echo "     curl -sSL https://github.com/vmware/govmomi/releases/latest/download/govc_Linux_x86_64.tar.gz | tar -C ~/.local/bin -xzf - govc" >&2
  echo "     export PATH=\"\$HOME/.local/bin:\$PATH\"" >&2
  exit 2; }

[ -n "${GOVC_URL:-}" ] || {
  echo "!! GOVC_URL is not set. Find the vCenter FQDN with:" >&2
  echo "     python3 scripts/octopus-project-state.py iaac-talos | grep -i -E 'vsphere|vcenter'" >&2
  exit 2; }

# Preflight. A failed login must abort, not produce an empty inventory that reads as
# "there is nothing there" — the exact false-absence that has bitten this work repeatedly.
if ! about=$(govc about 2>&1); then
  echo "!! cannot reach vCenter at ${GOVC_URL}:" >&2
  echo "   ${about}" >&2
  echo "!! ABORTING. An empty result here would look identical to an empty vCenter." >&2
  exit 3
fi
echo "vCenter: ${GOVC_URL}"
echo "$about" | sed -n '1,3p' | sed 's/^/  /'

SEARCH="${FOLDER:-/}"
echo
echo "Enumerating VMs under ${SEARCH} ..."
mapfile -t VMS < <(govc find "$SEARCH" -type m 2>/dev/null)
if [ "${#VMS[@]}" -eq 0 ]; then
  echo "!! no VMs found under ${SEARCH}." >&2
  echo "!! That is either a wrong path or a permissions boundary — not evidence the" >&2
  echo "!! inventory is empty. Try: govc ls / ; govc ls /*/vm" >&2
  exit 3
fi
echo "  ${#VMS[@]} VMs"

WORK="$(mktemp -d)"
TMP="$WORK/inventory.csv"
trap 'rm -rf "$WORK"' EXIT

# The inventory path (which folder a VM lives in) comes from `find`, not from vm.info —
# vm.info reports the DATASTORE path. Join the two on VM name, which is the last segment.
printf '%s\n' "${VMS[@]}" > "$WORK/paths.txt"

# One govc call per VM meant 383 round trips. vm.info takes many paths at once; batch it.
: > "$WORK/vms.json"
BATCH=60
i=0
while [ $i -lt ${#VMS[@]} ]; do
  chunk=("${VMS[@]:i:BATCH}")
  if ! govc vm.info -json "${chunk[@]}" >> "$WORK/vms.json" 2>"$WORK/err.txt"; then
    echo "!! govc vm.info failed on a batch starting at index $i:" >&2
    sed 's/^/   /' "$WORK/err.txt" >&2
    exit 3
  fi
  i=$(( i + BATCH ))
  printf '\r  fetched %d/%d' "$(( i < ${#VMS[@]} ? i : ${#VMS[@]} ))" "${#VMS[@]}"
done
echo

# Write the parser to a FILE. `python3 - <<'PY' <<<"$json"` has two stdin redirections;
# the here-string wins, so Python reads the JSON as its own source and dies on `null`.
cat > "$WORK/parse.py" <<'PY'
import csv, json, sys
from pathlib import Path

work = Path(sys.argv[1])
by_name = {}
for line in (work / "paths.txt").read_text().splitlines():
    line = line.strip()
    if line:
        by_name[line.rsplit("/", 1)[-1]] = line

def g(d, *keys):
    """vm.info -json capitalises differently across govc versions."""
    for k in keys:
        if isinstance(d, dict) and k in d and d[k] is not None:
            return d[k]
    return None

# Concatenated JSON documents, one per batch.
docs, dec, buf = [], json.JSONDecoder(), (work / "vms.json").read_text()
idx = 0
while idx < len(buf):
    while idx < len(buf) and buf[idx] in " \t\r\n":
        idx += 1
    if idx >= len(buf):
        break
    obj, idx = dec.raw_decode(buf, idx)
    docs.append(obj)

rows = []
for d in docs:
    for vm in (g(d, "virtualMachines", "VirtualMachines") or []):
        s = g(vm, "summary", "Summary") or {}
        cfg = g(s, "config", "Config") or {}
        rt = g(s, "runtime", "Runtime") or {}
        gu = g(s, "guest", "Guest") or {}
        st = g(s, "storage", "Storage") or {}
        name = g(cfg, "name", "Name") or ""
        prov = ((g(st, "committed", "Committed") or 0) +
                (g(st, "uncommitted", "Uncommitted") or 0)) / (1024 ** 3)
        rows.append({
            "Name": name,
            "Path": by_name.get(name, ""),
            "PowerState": g(rt, "powerState", "PowerState") or "",
            "vCPU": g(cfg, "numCpu", "NumCpu") or 0,
            "MemoryGB": round((g(cfg, "memorySizeMB", "MemorySizeMB") or 0) / 1024, 1),
            "ProvisionedGB": round(prov, 1),
            "GuestOS": (g(cfg, "guestFullName", "GuestFullName") or "").replace(",", ";"),
            "IP": g(gu, "ipAddress", "IpAddress") or "",
        })

if not rows:
    sys.exit("!! parsed 0 VMs from govc output — its JSON shape has changed.\n"
             "!! Check with: govc vm.info -json <one-vm-path> | head -40")

with (work / "inventory.csv").open("w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
    w.writeheader()
    w.writerows(rows)

def total(k):
    return sum(float(r[k] or 0) for r in rows)

on = [r for r in rows if r["PowerState"] == "poweredOn"]
off = [r for r in rows if r["PowerState"] != "poweredOn"]
print(f"\n  {len(rows)} VMs · {total('vCPU'):.0f} vCPU · {total('MemoryGB'):.0f} GB RAM · "
      f"{total('ProvisionedGB')/1024:.2f} TB provisioned")
print(f"  powered on: {len(on)}   powered off: {len(off)}")

talos = [r for r in rows if "talos" in r["Name"].lower() or "/TalosD1/" in r["Path"]]
if talos:
    tv = sum(float(r["vCPU"] or 0) for r in talos)
    tm = sum(float(r["MemoryGB"] or 0) for r in talos)
    td = sum(float(r["ProvisionedGB"] or 0) for r in talos)
    print(f"\n  Of which Talos-looking: {len(talos)} VMs · {tv:.0f} vCPU · {tm:.0f} GB · "
          f"{td/1024:.2f} TB")
    print("  (name/folder heuristic only — talos-vm-reconcile.py decides ownership from state)")

if off:
    # A powered-off VM costs nothing in a vCPU count and everything in a storage bill.
    print(f"\n  Powered OFF but still holding {sum(float(r['ProvisionedGB'] or 0) for r in off)/1024:.2f} TB:")
    for r in sorted(off, key=lambda r: -float(r["ProvisionedGB"] or 0))[:25]:
        print(f"    {r['Name']:<40} {float(r['ProvisionedGB'] or 0):>8.1f} GB   {r['Path']}")
    if len(off) > 25:
        print(f"    ... and {len(off) - 25} more, all in the CSV")
PY

python3 "$WORK/parse.py" "$WORK" || exit 3

if [ -n "$CSV" ]; then
  cp "$TMP" "$CSV"
  echo
  echo "  CSV written: $CSV"
  echo "  Next:  python3 scripts/talos-vm-reconcile.py --diff $CSV"
else
  echo
  echo "  Re-run with --csv <path> to feed this into talos-vm-reconcile.py."
fi

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

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
printf 'Name,Path,PowerState,vCPU,MemoryGB,ProvisionedGB,GuestOS,IP\n' > "$TMP"

for p in "${VMS[@]}"; do
  json=$(govc vm.info -json "$p" 2>/dev/null) || continue
  python3 - "$p" >> "$TMP" <<'PY' <<<"$json"
import json, sys
path = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
vms = d.get("virtualMachines") or d.get("VirtualMachines") or []
for vm in vms:
    s = vm.get("summary") or vm.get("Summary") or {}
    cfg = s.get("config") or s.get("Config") or {}
    rt = s.get("runtime") or s.get("Runtime") or {}
    g = s.get("guest") or s.get("Guest") or {}
    st = s.get("storage") or s.get("Storage") or {}
    committed = (st.get("committed") or st.get("Committed") or 0)
    uncommitted = (st.get("uncommitted") or st.get("Uncommitted") or 0)
    prov = round((committed + uncommitted) / (1024**3), 1)
    row = [
        cfg.get("name") or cfg.get("Name") or "",
        path,
        rt.get("powerState") or rt.get("PowerState") or "",
        str(cfg.get("numCpu") or cfg.get("NumCpu") or ""),
        str(round((cfg.get("memorySizeMB") or cfg.get("MemorySizeMB") or 0) / 1024, 1)),
        str(prov),
        (cfg.get("guestFullName") or cfg.get("GuestFullName") or "").replace(",", ";"),
        g.get("ipAddress") or g.get("IpAddress") or "",
    ]
    print(",".join('"%s"' % c.replace('"', "'") for c in row))
PY
done

rows=$(( $(wc -l < "$TMP") - 1 ))
if [ "$rows" -lt 1 ]; then
  echo "!! found ${#VMS[@]} VM paths but parsed 0 of them — govc's JSON shape has changed." >&2
  echo "!! Check with: govc vm.info -json '${VMS[0]}' | head -40" >&2
  exit 3
fi

python3 - "$TMP" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1], newline="")))
def num(r, k):
    try: return float(r[k] or 0)
    except ValueError: return 0.0
on  = [r for r in rows if r["PowerState"] == "poweredOn"]
off = [r for r in rows if r["PowerState"] != "poweredOn"]
print(f"\n  {len(rows)} VMs · {sum(num(r,'vCPU') for r in rows):.0f} vCPU · "
      f"{sum(num(r,'MemoryGB') for r in rows):.0f} GB RAM · "
      f"{sum(num(r,'ProvisionedGB') for r in rows)/1024:.2f} TB provisioned")
print(f"  powered on: {len(on)}   powered off: {len(off)}")
if off:
    # Powered-off VMs still consume storage. They are the cheapest thing to reclaim
    # and the easiest to overlook in a CPU/RAM conversation.
    gb = sum(num(r,'ProvisionedGB') for r in off)
    print(f"\n  Powered OFF but still holding {gb/1024:.2f} TB:")
    for r in sorted(off, key=lambda r: -num(r,'ProvisionedGB')):
        print(f"    {r['Name']:<38} {num(r,'ProvisionedGB'):>8.1f} GB   {r['Path']}")
PY

if [ -n "$CSV" ]; then
  cp "$TMP" "$CSV"
  echo
  echo "  CSV written: $CSV"
  echo "  Next:  python3 scripts/talos-vm-reconcile.py --diff $CSV"
else
  echo
  echo "  Re-run with --csv <path> to feed this into talos-vm-reconcile.py."
fi

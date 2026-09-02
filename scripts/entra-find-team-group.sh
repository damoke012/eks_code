#!/usr/bin/env bash
# INFRA-1639 -- find the Entra group that represents the application team, so Argo CD
# access is granted to a GROUP once instead of to each person.
#
# READ-ONLY. Only `az ad ... show/list`. It changes nothing.
#
# Two searches, because a name search alone assumes we can guess the naming convention:
#   1. What groups do the named people actually belong to, and which do they SHARE?
#      The shared set is the empirical answer -- it does not depend on a naming guess.
#   2. A name search over likely fragments, to catch a correctly-named group nobody is
#      in yet.
#
# It also prints onPremisesSyncEnabled per group. That decides WHO can add members:
# a group synced from on-prem AD cannot be edited in Entra -- membership changes are
# made in Active Directory, which is the service desk's normal path.
#
#   scripts/entra-find-team-group.sh pkoirala@usxpress.com
#   scripts/entra-find-team-group.sh pkoirala@usxpress.com someone.else@usxpress.com
set -uo pipefail
TENANT="${TENANT:-bbb5a66d-5c9f-482a-969a-a40304b6bc8d}"
APP_ID="${APP_ID:-42dc0c33-4c56-47a5-b207-d119272997aa}"   # Argo CD On-Prem

command -v az >/dev/null 2>&1 || { echo "!! az is not on PATH. Run this on WSL." >&2; exit 2; }
TID=$(az account show --query tenantId --output tsv 2>/dev/null || true)
[ "$TID" = "$TENANT" ] || { echo "!! signed in to tenant '${TID:-<none>}', expected $TENANT" >&2
                            echo "   az login --tenant $TENANT" >&2; exit 2; }
[ $# -gt 0 ] || { echo "!! give at least one UPN, e.g. $0 pkoirala@usxpress.com" >&2; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

echo "== groups each person belongs to"
for upn in "$@"; do
  if ! oid=$(az ad user show --id "$upn" --query id -o tsv 2>"$WORK/e"); then
    echo "  !! cannot read $upn: $(tail -1 "$WORK/e")" >&2
    echo "  !! ABORTING -- a user this run could not read would look like someone in no" >&2
    echo "  !! groups, and the intersection below would be silently wrong." >&2
    exit 3
  fi
  az ad user get-member-groups --id "$oid" --query "[].{id:id,name:displayName}" -o json \
    > "$WORK/$(echo "$upn" | tr -c 'a-zA-Z0-9' _).json" 2>/dev/null \
    || echo '[]' > "$WORK/$(echo "$upn" | tr -c 'a-zA-Z0-9' _).json"
  n=$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))))" "$WORK/$(echo "$upn" | tr -c 'a-zA-Z0-9' _).json")
  printf '  %-34s %s groups\n' "$upn" "$n"
done

python3 - "$WORK" "$@" <<'PY'
import json, sys, os
work = sys.argv[1]; upns = sys.argv[2:]
sets, names = [], {}
for u in upns:
    f = os.path.join(work, "".join(c if c.isalnum() else "_" for c in u) + ".json")
    data = json.load(open(f))
    ids = set()
    for g in data:
        ids.add(g["id"]); names[g["id"]] = g["name"]
    sets.append(ids)
common = set.intersection(*sets) if sets else set()
print(f"\n== shared by all {len(upns)} ({len(common)})")
if not common:
    print("   none -- they have no group in common, so there is no existing team group to reuse.")
for gid in sorted(common, key=lambda g: names[g].lower()):
    print(f"   {names[gid]:<52} {gid}")
open(os.path.join(work, "common.txt"), "w").write("\n".join(sorted(common)))
PY

echo
echo "== detail on the shared groups (who can add members?)"
while read -r gid; do
  [ -n "$gid" ] || continue
  az ad group show --group "$gid" \
    --query "{name:displayName, id:id, security:securityEnabled, mail:mailEnabled, synced:onPremisesSyncEnabled, desc:description}" \
    -o json 2>/dev/null | python3 -c '
import json,sys
g=json.load(sys.stdin)
src = "on-prem AD (edit in AD, not Entra)" if g.get("synced") else "cloud-only (edit in Entra)"
print(f"   {g[\"name\"]}")
print(f"     id       {g[\"id\"]}")
print(f"     type     security={g.get(\"security\")} mail={g.get(\"mail\")}")
print(f"     managed  {src}")
if g.get("desc"): print(f"     desc     {g[\"desc\"]}")
'
done < "$WORK/common.txt"

echo
echo "== name search, for a correctly-named group nobody is in yet"
for frag in risingwave rising-wave "rising wave" etl datalake "data eng" platform devops kubernetes argocd argo; do
  out=$(az ad group list --filter "startswith(displayName,'$frag')" \
        --query "[].{n:displayName,i:id}" -o tsv 2>/dev/null)
  [ -n "$out" ] && { echo "  '$frag':"; echo "$out" | sed 's/^/     /'; }
done
az ad group list --display-name "usx-cloud-admin" --query "[].{n:displayName,i:id}" -o tsv 2>/dev/null \
  | sed 's/^/  reference (already assigned to the admin role): /'

echo
echo "== who is assigned to Argo CD On-Prem today"
SP=$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null)
if [ -n "$SP" ]; then
  az rest --method GET \
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SP/appRoleAssignedTo?\$select=principalDisplayName,principalType,appRoleId" \
    --query "value[].{who:principalDisplayName,kind:principalType}" -o table 2>/dev/null \
    || echo "   (could not read assignments -- needs directory read)"
else
  echo "   (service principal not readable)"
fi

echo
echo "Nothing was changed. To grant, once a group is chosen:"
echo "  bash scripts/entra-argocd-app-roles.sh --assign app-viewer <that group's id>"

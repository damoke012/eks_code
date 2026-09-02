#!/usr/bin/env bash
# INFRA-1639 -- find the Entra group that represents the application team, so Argo CD
# access is granted to a GROUP once instead of to each person.
#
# READ-ONLY. Only `az ad ... show/list` and Graph GETs. It changes nothing.
#
# Three views:
#   1. What groups the named people belong to, and which they SHARE. Empirical -- it does
#      not depend on guessing a naming convention.
#   2. A name search over likely fragments, to catch a correctly-named group nobody is in.
#   3. Who is assigned to Argo CD On-Prem today, WITH the role each assignment carries.
#
# It prints onPremisesSyncEnabled per group, which decides who can add members: a group
# synced from on-prem AD cannot be edited in Entra -- membership is changed in Active
# Directory, the service desk's normal path.
#
#   scripts/entra-find-team-group.sh pkoirala@usxpress.com "Tim Wolfe"
#   scripts/entra-find-team-group.sh --members Risingwave
#
# Arguments may be a UPN (contains @) or a display name, which is resolved first.
set -uo pipefail
TENANT="${TENANT:-bbb5a66d-5c9f-482a-969a-a40304b6bc8d}"
APP_ID="${APP_ID:-42dc0c33-4c56-47a5-b207-d119272997aa}"   # Argo CD On-Prem

command -v az >/dev/null 2>&1 || { echo "!! az is not on PATH. Run this on WSL." >&2; exit 2; }
TID=$(az account show --query tenantId --output tsv 2>/dev/null || true)
[ "$TID" = "$TENANT" ] || { echo "!! signed in to tenant '${TID:-<none>}', expected $TENANT" >&2
                            echo "   az login --tenant $TENANT" >&2; exit 2; }
[ $# -gt 0 ] || { echo "!! usage: $0 <upn-or-name> [more...]   |   $0 --members <group>" >&2; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ── --members: list one group's membership ───────────────────────────────────
if [ "$1" = "--members" ]; then
  [ $# -ge 2 ] || { echo "!! --members needs a group name or object id" >&2; exit 2; }
  G="$2"
  if ! gid=$(az ad group show --group "$G" --query id -o tsv 2>"$WORK/e"); then
    echo "!! cannot resolve group '$G': $(tail -1 "$WORK/e")" >&2; exit 3
  fi
  az ad group show --group "$gid" \
    --query "{name:displayName,id:id,security:securityEnabled,mail:mailEnabled,synced:onPremisesSyncEnabled,desc:description}" \
    -o json | python3 -c '
import json,sys
g=json.load(sys.stdin)
print(f"\n{g[\"name\"]}  ({g[\"id\"]})")
print("  managed in", "on-prem AD -- membership changes go through AD, not Entra"
      if g.get("synced") else "Entra (cloud-only)")
print(f"  security={g.get(\"security\")}  mail={g.get(\"mail\")}")
if g.get("desc"): print(f"  {g[\"desc\"]}")
'
  echo
  echo "  members:"
  az ad group member list --group "$gid" \
    --query "sort_by([].{name:displayName,upn:userPrincipalName}, &name)" -o tsv 2>/dev/null \
    | sed 's/^/    /' || echo "    (could not read members -- needs directory read)"
  exit 0
fi

# ── group membership per person, and the intersection ────────────────────────
echo "== groups each person belongs to"
i=0
LABELS=()
for who in "$@"; do
  i=$((i+1))
  if [[ "$who" == *"@"* ]]; then
    query="$who"
  else
    # Resolve a display name to a UPN first, so the caller need not know it.
    query=$(az ad user list --filter "displayName eq '$who'" --query "[0].userPrincipalName" -o tsv 2>/dev/null)
    [ -n "$query" ] && [ "$query" != "None" ] || {
      echo "  !! no user matches display name '$who' — pass their UPN instead" >&2; exit 3; }
    echo "  ($who resolves to $query)"
  fi
  if ! oid=$(az ad user show --id "$query" --query id -o tsv 2>"$WORK/e"); then
    echo "  !! cannot read $query: $(tail -1 "$WORK/e")" >&2
    echo "  !! ABORTING — a user this run could not read looks like someone in no groups," >&2
    echo "  !! and the intersection below would be silently empty." >&2
    exit 3
  fi
  # Index-based filenames. The previous version derived the name with `tr -c` in bash and
  # str.join in Python; `tr` also replaced the trailing newline, so the two disagreed by
  # one underscore and Python could not open the file bash had just written.
  az ad user get-member-groups --id "$oid" --query "[].{id:id,name:displayName}" -o json \
    > "$WORK/$i.json" 2>/dev/null || echo '[]' > "$WORK/$i.json"
  n=$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))))" "$WORK/$i.json")
  printf '  %-34s %s groups\n' "$query" "$n"
  LABELS+=("$query")
done

python3 - "$WORK" "$#" "${LABELS[@]}" <<'PY'
import json, os, sys
work, n = sys.argv[1], int(sys.argv[2]); labels = sys.argv[3:]
sets, names = [], {}
for i in range(1, n + 1):
    data = json.load(open(os.path.join(work, f"{i}.json")))
    ids = set()
    for g in data:
        ids.add(g["id"]); names[g["id"]] = g["name"]
    sets.append(ids)
common = set.intersection(*sets) if sets else set()
print(f"\n== shared by all {n} ({len(common)})")
if not common:
    print("   none — they share no group, so there is no existing team group to reuse.")
for gid in sorted(common, key=lambda g: names[g].lower()):
    print(f"   {names[gid]:<52} {gid}")
open(os.path.join(work, "common.txt"), "w").write("\n".join(sorted(common)))
PY

echo
echo "== detail on the shared groups (who can add members?)"
while read -r gid; do
  [ -n "$gid" ] || continue
  az ad group show --group "$gid" \
    --query "{name:displayName,id:id,security:securityEnabled,mail:mailEnabled,synced:onPremisesSyncEnabled,desc:description}" \
    -o json 2>/dev/null | python3 -c '
import json,sys
g=json.load(sys.stdin)
src = "on-prem AD (edit in AD, not Entra)" if g.get("synced") else "cloud-only (edit in Entra)"
print(f"   {g[\"name\"]}")
print(f"     id       {g[\"id\"]}")
print(f"     managed  {src}")
if g.get("desc"): print(f"     desc     {g[\"desc\"]}")
'
done < "$WORK/common.txt"

echo
echo "== name search, for a correctly-named group nobody is in yet"
for frag in risingwave etl "data eng" platform devops kubernetes argo; do
  out=$(az ad group list --filter "startswith(displayName,'$frag')" \
        --query "[].{n:displayName,i:id}" -o tsv 2>/dev/null)
  [ -n "$out" ] && { echo "  '$frag':"; echo "$out" | sed 's/^/     /'; }
done

echo
echo "== who is assigned to Argo CD On-Prem today, and with which role"
SP=$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null)
if [ -n "$SP" ]; then
  az ad sp show --id "$APP_ID" --query "appRoles[].{id:id,value:value}" -o json > "$WORK/roles.json" 2>/dev/null
  az rest --method GET \
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SP/appRoleAssignedTo" \
    -o json > "$WORK/assign.json" 2>/dev/null
  python3 - "$WORK" <<'PY'
import json, os, sys
work = sys.argv[1]
try:
    roles = {r["id"]: r["value"] for r in json.load(open(os.path.join(work, "roles.json")))}
    rows = json.load(open(os.path.join(work, "assign.json"))).get("value", [])
except Exception as e:
    sys.exit(f"   (could not read assignments: {e})")
if not rows:
    sys.exit("   (no assignments returned)")
print(f"   {'who':<24} {'kind':<8} role")
for a in sorted(rows, key=lambda a: (roles.get(a.get("appRoleId"), ""), a.get("principalDisplayName", ""))):
    role = roles.get(a.get("appRoleId")) or "(default access — no role)"
    print(f"   {a.get('principalDisplayName',''):<24} {a.get('principalType',''):<8} {role}")
PY
else
  echo "   (service principal not readable)"
fi

echo
echo "Nothing was changed. Once a group is chosen:"
echo "  bash scripts/entra-argocd-app-roles.sh --assign app-viewer <that group's id>"

#!/usr/bin/env bash
# INFRA-1639 -- route AROUND the missing groups claim, using app roles.
#
# THE PROBLEM. Entra issues a valid ID token for `Argo CD On-Prem` with no `groups`
# claim, under groupMembershipClaims SecurityGroup and ApplicationGroup alike, with
# `groups` in optionalClaims.idToken, no claims-mapping policy, and the user in 42
# groups (far under the ~200 overage threshold). policy.csv therefore matches nothing
# and policy.default "" applies. See wip/onprem-argocd/FINDINGS-2026-08-25-entra-oidc.md.
#
# THE ROUTE AROUND IT. `roles` is a different claim with a different issuance path:
# it comes from appRoleAssignments on the service principal, not from directory group
# membership, so a tenant control that suppresses group claims does not touch it. And
# Argo CD reads RBAC subjects from whatever claims `configs.rbac.scopes` names --
# default '[groups]', but '[roles, groups]' makes it match either.
#
# This is entirely inside the app registration WE created and own on 2026-08-25.
# It needs nothing from whoever owns the tenant.
#
# WHAT IS NOT PROVEN. That a real token comes back carrying `roles`. Nothing here
# asserts it does: --inspect after --define/--assign shows the configuration, and the
# only evidence that counts is a fresh login read through scripts/argocd-token-claims.sh.
# Assigning a GROUP (rather than a user) to an app role requires Entra ID P1. If the
# tenant is not licensed for it, --assign fails loudly and the fallback is per-user
# assignment, which works on any tier.
#
#   scripts/entra-argocd-app-roles.sh --inspect
#   scripts/entra-argocd-app-roles.sh --define
#   scripts/entra-argocd-app-roles.sh --assign platform-admin b9a1ff74-efa1-4b20-be8a-8706a5ab2636
set -euo pipefail

APP_ID="${APP_ID:-42dc0c33-4c56-47a5-b207-d119272997aa}"   # Argo CD On-Prem, created 2026-08-25
TENANT="${TENANT:-bbb5a66d-5c9f-482a-969a-a40304b6bc8d}"
MODE="--inspect"
[ $# -gt 0 ] && MODE="$1"

command -v az >/dev/null 2>&1 || { echo "!! az is not on PATH. Run this on WSL." >&2; exit 2; }

TID=$(az account show --query tenantId --output tsv 2>/dev/null || true)
[ "$TID" = "$TENANT" ] || { echo "!! signed in to tenant '${TID:-<none>}', expected $TENANT" >&2
                            echo "   az login --tenant $TENANT" >&2; exit 2; }

OBJ=$(az ad app show --id "$APP_ID" --query id --output tsv)
SP=$(az ad sp show --id "$APP_ID" --query id --output tsv)
echo "   app object $OBJ   service principal $SP"

# Role IDs are derived from the role value, so re-running --define produces the
# SAME ids and is a no-op rather than a duplicate-role error.
role_id() { python3 -c "
import uuid,sys
print(uuid.uuid5(uuid.UUID('$APP_ID'), sys.argv[1]))" "$1"; }

inspect() {
  echo
  echo "--- optionalClaims, in full ---"
  # Read this before concluding anything about the roles claim. Entra's `groups`
  # optional claim takes additionalProperties, and one of them -- emit_as_roles --
  # moves group values INTO the roles claim and out of the groups claim. If that is
  # set, "no groups claim" is the configured behaviour and the values are already
  # in `roles` under a different name than we expect.
  az ad app show --id "$APP_ID" --query optionalClaims --output json
  echo
  echo "--- appRoles defined on the registration ---"
  az ad app show --id "$APP_ID" \
    --query 'appRoles[].{value:value,display:displayName,enabled:isEnabled,members:allowedMemberTypes[0],id:id}' \
    --output table 2>/dev/null || echo "   (none)"
  echo
  echo "--- who is assigned, and to which role ---"
  # The default-access assignment (appRoleId all-zeroes) is what appRoleAssignmentRequired
  # created when the group was assigned with no roles defined. It emits NO roles claim.
  az rest --method GET \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$SP/appRoleAssignedTo" \
    --query 'value[].{principal:principalDisplayName,type:principalType,appRoleId:appRoleId}' \
    --output table
  echo
  echo "   appRoleId 00000000-0000-0000-0000-000000000000 is 'default access' --"
  echo "   it satisfies appRoleAssignmentRequired but emits NOTHING in the token."
  echo
  echo "--- what Argo needs alongside this ---"
  echo "   configs.rbac.scopes must name the claim:  '[roles, groups]'"
  echo "   and policy.csv subjects become the role VALUE, e.g.  g, platform-admin, role:admin"
}

case "$MODE" in
  --inspect) inspect ;;

  --define)
    ADMIN_ID=$(role_id platform-admin)
    VIEWER_ID=$(role_id app-viewer)
    OPERATOR_ID=$(role_id app-operator)
    TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
    # Preserve anything already defined -- --app-roles REPLACES the list wholesale,
    # the same shape as --web-redirect-uris, which is why the cloud fleet's app was
    # left alone in the first place.
    az ad app show --id "$APP_ID" --query appRoles --output json > "$TMP"
    python3 - "$TMP" "$ADMIN_ID" "$VIEWER_ID" "$OPERATOR_ID" <<'PY'
import json, sys
path, admin_id, viewer_id, operator_id = sys.argv[1:5]
roles = json.load(open(path)) or []
want = {
  "platform-admin": {
    "id": admin_id, "isEnabled": True, "allowedMemberTypes": ["User"],
    "displayName": "Argo CD platform admin",
    "value": "platform-admin",
    "description": "Full Argo CD access on the on-prem clusters. Maps to role:admin in policy.csv.",
  },
  "app-viewer": {
    "id": viewer_id, "isEnabled": True, "allowedMemberTypes": ["User"],
    "displayName": "Argo CD application viewer",
    "value": "app-viewer",
    "description": "Read-only view of one AppProject, plus sync on dev and QA. Maps to role:app-viewer.",
  },
  # Added 2026-09-02 (Doke's call): the application team operates its own pipeline on
  # every environment, production included. app-viewer stays read-only for people who
  # only need visibility.
  "app-operator": {
    "id": operator_id, "isEnabled": True, "allowedMemberTypes": ["User"],
    "displayName": "Argo CD application operator",
    "value": "app-operator",
    "description": "One AppProject: read, logs, sync and pod restart on dev, QA AND prod. Maps to role:app-operator.",
  },
}
by_value = {r.get("value"): r for r in roles}
for v, r in want.items():
    if v in by_value:
        # A role already defined with a DIFFERENT id would silently split assignments
        # across two roles, one of which nobody holds.
        assert by_value[v]["id"] == r["id"], (
            "role %r already exists with id %s, expected %s -- resolve by hand"
            % (v, by_value[v]["id"], r["id"]))
        print("   %-15s already defined" % v)
    else:
        roles.append(r); print("   %-15s adding" % v)
json.dump(roles, open(path, "w"), indent=2)
PY
    az ad app update --id "$APP_ID" --app-roles "@$TMP"
    echo "   appRoles written"
    inspect
    ;;

  --assign)
    VALUE="${2:-}"; PRINCIPAL="${3:-}"
    [ -n "$VALUE" ] && [ -n "$PRINCIPAL" ] || {
      echo "!! usage: $0 --assign <roleValue> <group-or-user-objectId>" >&2; exit 2; }
    RID=$(az ad app show --id "$APP_ID" \
            --query "appRoles[?value=='$VALUE'].id | [0]" --output tsv)
    [ -n "$RID" ] && [ "$RID" != "None" ] || {
      echo "!! no appRole with value '$VALUE' -- run --define first" >&2; exit 1; }
    # Name the principal before writing, so a typo'd object ID is caught here rather
    # than surfacing as "SSO works but grants nothing" a week later.
    PNAME=$(az rest --method GET \
              --uri "https://graph.microsoft.com/v1.0/directoryObjects/$PRINCIPAL" \
              --query 'displayName' --output tsv 2>/dev/null || true)
    [ -n "$PNAME" ] || { echo "!! $PRINCIPAL is not a readable directory object" >&2; exit 1; }
    echo "   assigning '$VALUE' ($RID) to $PNAME"
    ERR_OUT=$(az rest --method POST \
      --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$SP/appRoleAssignedTo" \
      --headers 'Content-Type=application/json' \
      --body "{\"principalId\":\"$PRINCIPAL\",\"resourceId\":\"$SP\",\"appRoleId\":\"$RID\"}" \
      --output none 2>&1) && echo "   assigned" || {
      # Re-running is normal -- this script is meant to be safe to repeat, and the
      # first version reported the idempotent case as a failure and then pointed at
      # a licence limit that had nothing to do with it.
      case "$ERR_OUT" in
        *"already exists on the object"*)
          echo "   already assigned -- nothing to do" ;;
        *[Ll]icense*|*[Ll]icence*|*subscription*|*Subscription*)
          cat >&2 <<'ERR'
!! assigning a GROUP to an app role requires Entra ID P1, and this tenant will not
   allow it. Assign the individual user instead -- that works on any tier and proves
   the roles claim arrives before anyone has to buy anything:

     az ad signed-in-user show --query id --output tsv
ERR
          exit 1 ;;
        *)
          echo "!! the assignment failed:" >&2
          printf '   %s\n' "$(printf '%s' "$ERR_OUT" | head -3)" >&2
          exit 1 ;;
      esac
    }
    inspect
    ;;

  *) echo "usage: $0 [--inspect|--define|--assign <roleValue> <objectId>]" >&2; exit 2 ;;
esac

cat <<'NEXT'

Next, and this is the only step that proves anything:
  1. sign out of Argo CD completely, then sign in again -- a token minted before this
     change tests the old configuration, which has already cost three runs
  2. scripts/argocd-token-claims.sh op-dev      # or op-qa / op-prod
     look for ROLES in the claim list. GROUPS may well still be absent; it no longer
     matters if ROLES is there.
NEXT

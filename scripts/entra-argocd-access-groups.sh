#!/usr/bin/env bash
# Argo CD on-prem access, managed by GROUP instead of per person.
#
# Three tiers, one group each. After this runs, granting someone Argo CD access is
# adding them to a group — nobody touches Entra or Argo CD again.
#
#   usx-cloud-admin      (already exists)  you + Idris        role platform-admin
#   usx-argocd-operator  (created here)    Tim + Pujit        role app-operator
#   usx-argocd-viewer    (created here)    Jenny Ray          role app-viewer
#
# DRY RUN BY DEFAULT. Pass --apply to create groups, add members and assign roles.
#
#   bash scripts/entra-argocd-access-groups.sh
#   bash scripts/entra-argocd-access-groups.sh --apply
#   bash scripts/entra-argocd-access-groups.sh --find Ray      # look a person up first
#
# Members are display names or UPNs; a display name is resolved first, and a name that
# matches nothing ABORTS rather than quietly creating a group with a person missing.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TENANT="${TENANT:-bbb5a66d-5c9f-482a-969a-a40304b6bc8d}"
APP_ID="${APP_ID:-42dc0c33-4c56-47a5-b207-d119272997aa}"
APPLY="no"; [ "${1:-}" = "--apply" ] && APPLY="yes"

if [ "${1:-}" = "--find" ]; then
  [ -n "${2:-}" ] || { echo "!! --find needs a name fragment" >&2; exit 2; }
  command -v az >/dev/null 2>&1 || { echo "!! az is not on PATH. Run this on WSL." >&2; exit 2; }
  echo "surname starts with '$2':"
  az ad user list --filter "startswith(surname,'$2')" \
    --query "sort_by([].{name:displayName,upn:userPrincipalName}, &name)" -o tsv 2>/dev/null | sed 's/^/  /'
  echo "display name starts with '$2':"
  az ad user list --filter "startswith(displayName,'$2')" \
    --query "sort_by([].{name:displayName,upn:userPrincipalName}, &name)" -o tsv 2>/dev/null | sed 's/^/  /'
  exit 0
fi

# name | mailNickname | role value | members (comma separated)
# UPNs, not display names. "Tim Wolfe" was a GUESSED name on 2026-09-02 and matched
# nobody; the real one — Timothy Preble — was already in the Risingwave group listing.
# Override either list without editing this file:
#   OPERATOR_MEMBERS=a@x,b@x VIEWER_MEMBERS=c@x bash scripts/entra-argocd-access-groups.sh
OPERATOR_MEMBERS="${OPERATOR_MEMBERS:-tpreble@usxpress.com,pkoirala@usxpress.com}"
VIEWER_MEMBERS="${VIEWER_MEMBERS:-}"
TIERS=(
  "usx-argocd-operator|usx-argocd-operator|app-operator|$OPERATOR_MEMBERS"
  "usx-argocd-viewer|usx-argocd-viewer|app-viewer|$VIEWER_MEMBERS"
)

command -v az >/dev/null 2>&1 || { echo "!! az is not on PATH. Run this on WSL." >&2; exit 2; }
TID=$(az account show --query tenantId --output tsv 2>/dev/null || true)
[ "$TID" = "$TENANT" ] || { echo "!! signed in to tenant '${TID:-<none>}', expected $TENANT" >&2
                            echo "   az login --tenant $TENANT" >&2; exit 2; }

resolve_user() {  # display name or UPN -> object id, or abort with candidates
  local who="$1" upn
  if [[ "$who" == *"@"* ]]; then upn="$who"
  else
    upn=$(az ad user list --filter "displayName eq '$who'" --query "[0].userPrincipalName" -o tsv 2>/dev/null)
    if [ -z "$upn" ] || [ "$upn" = "None" ]; then
      echo "!! no directory user is named exactly '$who'." >&2
      # An exact-match miss is usually a spelling guess. Show near matches instead of
      # just failing, so the caller can correct it in one step.
      local last; last="${who##* }"
      echo "!! near matches on '$last':" >&2
      az ad user list --filter "startswith(surname,'$last')" \
        --query "[].{n:displayName,u:userPrincipalName}" -o tsv 2>/dev/null | sed 's/^/     /' >&2
      az ad user list --filter "startswith(displayName,'${who%% *}')" \
        --query "[].{n:displayName,u:userPrincipalName}" -o tsv 2>/dev/null | sed 's/^/     /' >&2
      echo "!! ABORTING — a group created without them would look like it worked." >&2
      exit 3
    fi
  fi
  az ad user show --id "$upn" --query id -o tsv 2>/dev/null
}

echo "$( [ "$APPLY" = yes ] && echo EXECUTING || echo 'DRY RUN' ) — tenant $TENANT"
echo

for tier in "${TIERS[@]}"; do
  IFS='|' read -r NAME NICK ROLE MEMBERS <<< "$tier"
  echo "== $NAME  ->  app role '$ROLE'"

  GID=$(az ad group show --group "$NAME" --query id -o tsv 2>/dev/null)
  if [ -n "$GID" ]; then
    echo "   group exists: $GID"
  elif [ "$APPLY" != "yes" ]; then
    echo "   [plan] create security group '$NAME'"
    GID=""
  else
    GID=$(az ad group create --display-name "$NAME" --mail-nickname "$NICK" \
            --description "Argo CD on-prem: $ROLE. Membership IS the access." \
            --query id -o tsv) || { echo "   !! could not create '$NAME'" >&2; exit 3; }
    echo "   created: $GID"
  fi

  if [ -z "$MEMBERS" ]; then
    echo "   no members configured — set VIEWER_MEMBERS/OPERATOR_MEMBERS to populate it"
    echo
    continue
  fi
  IFS=',' read -ra WHO <<< "$MEMBERS"
  for w in "${WHO[@]}"; do
    OID=$(resolve_user "$w")
    [ -n "$OID" ] || { echo "   !! could not resolve '$w'" >&2; exit 3; }
    if [ "$APPLY" != "yes" ] || [ -z "$GID" ]; then
      echo "   [plan] add $w ($OID)"
    elif az ad group member check --group "$GID" --member-id "$OID" --query value -o tsv 2>/dev/null | grep -qi true; then
      echo "   already a member: $w"
    else
      az ad group member add --group "$GID" --member-id "$OID" >/dev/null 2>&1 \
        && echo "   added: $w" || echo "   !! failed to add $w"
    fi
  done

  if [ "$APPLY" != "yes" ] || [ -z "$GID" ]; then
    echo "   [plan] assign group to app role '$ROLE'"
  else
    bash "$SCRIPT_DIR/entra-argocd-app-roles.sh" --assign "$ROLE" "$GID" \
      || echo "   !! role assignment failed — assigning a GROUP to an app role needs Entra ID P1"
  fi
  echo
done

if [ "$APPLY" != "yes" ]; then
  cat <<'NEXT'
Dry run. Nothing was created. Pass --apply to execute.

Before --apply, run once so the app-operator role exists on the registration:
  bash scripts/entra-argocd-app-roles.sh --define

After --apply, TWO things are still required or nobody gains anything:
  1. Grant admin consent for the whole company on 'Argo CD On-Prem', or each new
     person hits the approval screen Pujit hit.
  2. Land role:app-operator in policy.csv on all three cluster branches. Until then
     the role is issued in the token and Argo CD matches it to nothing.
NEXT
fi

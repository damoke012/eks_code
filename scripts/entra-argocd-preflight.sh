#!/usr/bin/env bash
# INFRA-1639 -- can Argo CD on-prem use Entra OIDC directly, and what values would it need?
#
# READ-ONLY. Creates nothing, changes nothing. Run on WSL, where `az` is signed in.
#
# Why this exists: the Identity Center SAML route on op-dev is stuck on console-only
# state with no readback (see wip/onprem-argocd/). Entra is a real alternative and is
# NOT speculative here -- `az ad app update` already ran successfully against the
# `risingwave` app registration on 2026-08-13 (wip/rw-qa-operator-split/). Argo CD
# speaks OIDC natively, so this route deletes Dex rather than configuring it.
#
# Six gates. Each prints PASS / FAIL / UNKNOWN and the value the next step needs.
#
#   scripts/entra-argocd-preflight.sh op-dev
#   scripts/entra-argocd-preflight.sh op-dev --aws-profile op-dev
set -uo pipefail

BR="${1:-}"
AWS_PROFILE_ARG=""
[ "${2:-}" = "--aws-profile" ] && AWS_PROFILE_ARG="${3:-}"

case "$BR" in
  op-dev|op-qa|op-prod) : ;;
  *) echo "!! usage: $0 <op-dev|op-qa|op-prod> [--aws-profile NAME]" >&2; exit 2 ;;
esac

HOST="argocd.$BR.usxpress.io"
CALLBACK="https://$HOST/auth/callback"        # Argo NATIVE OIDC callback, not /api/dex/callback
GROUP="usx-cloud-admin"
RW_APP="e112d6ce-cc60-4884-9898-8fcc5b78b0b1"  # proven-writable app, from the 2026-08-13 note

pass=0; fail=0; unk=0
say() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
ok()   { printf '   \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '   \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
huh()  { printf '   \033[33m????\033[0m  %s\n' "$1"; unk=$((unk+1)); }
val()  { printf '         %s\n' "$1"; }

command -v az >/dev/null 2>&1 || { echo "!! az not on PATH -- run this on WSL" >&2; exit 2; }

# ---------------------------------------------------------------- gate 1: identity
say "1. Which Entra tenant, signed in as whom"
ACC=$(az account show -o json 2>&1) || { no "az account show failed -- run: az login"; echo "$ACC"; exit 1; }
TENANT=$(printf '%s' "$ACC" | python3 -c 'import sys,json; print(json.load(sys.stdin)["tenantId"])' 2>/dev/null)
UPN=$(printf '%s' "$ACC" | python3 -c 'import sys,json; print(json.load(sys.stdin)["user"]["name"])' 2>/dev/null)
if [ -n "${TENANT:-}" ]; then
  ok "signed in"
  val "tenantId : $TENANT"
  val "user     : $UPN"
  val "issuer   : https://login.microsoftonline.com/$TENANT/v2.0"
else
  no "could not parse tenantId"; fi

# ---------------------------- gate 2: may this identity CREATE an app registration?
say "2. May this identity create an app registration"
POL=$(az rest --method GET \
        --url https://graph.microsoft.com/v1.0/policies/authorizationPolicy -o json 2>&1) || POL=""
ALLOWED=$(printf '%s' "$POL" | python3 -c '
import sys,json
try:
    d=json.load(sys.stdin)
    d=d.get("value",[d])[0] if isinstance(d.get("value",None),list) else d
    print(d["defaultUserRolePermissions"]["allowedToCreateApps"])
except Exception: print("")' 2>/dev/null)
[ -z "$ALLOWED" ] && ALLOWED=$(printf '%s' "$POL" | python3 -c '
import sys,json
try:
    d=json.load(sys.stdin)
    d=d.get("value",[d])[0] if isinstance(d.get("value",None),list) else d
    print(d["defaultUserRolePermissions"]["allowedToCreateApplications"])
except Exception: print("")' 2>/dev/null)

ROLES=$(az rest --method GET \
   --url 'https://graph.microsoft.com/v1.0/me/memberOf/microsoft.graph.directoryRole?$select=displayName' \
   -o json 2>/dev/null | python3 -c '
import sys,json
try: print("; ".join(r.get("displayName","?") for r in json.load(sys.stdin).get("value",[])) or "(none)")
except Exception: print("(unreadable)")' 2>/dev/null)

val "tenant default 'users may register applications' : ${ALLOWED:-unreadable}"
val "directory roles held                            : ${ROLES:-unreadable}"
case "$ALLOWED" in
  True|true)  ok "every user may register apps -- az ad app create should work" ;;
  False|false)
    case "$ROLES" in
      *Application*|*Global*|*Cloud\ App*) ok "tenant default is off, but a directory role covers it" ;;
      *) no "tenant default is off and no app-admin role held -- creation will be denied" ;;
    esac ;;
  *) huh "tenant policy unreadable (needs Policy.Read.All); prove it by trying the create" ;;
esac
val "proven fallback: 'az ad app update --id $RW_APP' succeeded 2026-08-13,"
val "so UPDATE on an existing app is not in doubt even if CREATE is."

# --------------------------------------------- gate 3: does an argocd app exist yet
say "3. Is there already an Argo CD app registration"
APPS=$(az ad app list --all --query "[?contains(displayName,'rgo')].{name:displayName,appId:appId,uris:web.redirectUris}" -o json 2>&1) || APPS=""
if printf '%s' "$APPS" | grep -q '"appId"' 2>/dev/null; then
  ok "found existing candidate(s) -- reuse beats create"
  printf '%s\n' "$APPS" | sed 's/^/         /'
else
  huh "no app whose name contains 'rgo' -- a new registration is needed"
  val "(this listing needs Application.Read.All; an empty result here is not proof)"
fi

# ------------------------------- gate 4: the group, and HOW it will appear in a token
say "4. The RBAC group, and what Argo will actually receive as its name"
G=$(az ad group list --filter "displayName eq '$GROUP'" -o json 2>&1) || G=""
GID=$(printf '%s' "$G" | python3 -c '
import sys,json
try: print(json.load(sys.stdin)[0]["id"])
except Exception: print("")' 2>/dev/null)
if [ -n "$GID" ]; then
  ok "$GROUP resolves in Entra"
  val "objectId : $GID"
  SYNC=$(az rest --method GET \
     --url "https://graph.microsoft.com/v1.0/groups/$GID?\$select=onPremisesSyncEnabled,onPremisesSamAccountName,securityEnabled" \
     -o json 2>/dev/null)
  ONPREM=$(printf '%s' "$SYNC" | python3 -c '
import sys,json
try:
    d=json.load(sys.stdin); print("%s|%s|%s" % (d.get("onPremisesSyncEnabled"), d.get("onPremisesSamAccountName"), d.get("securityEnabled")))
except Exception: print("|| ")' 2>/dev/null)
  val "onPremisesSyncEnabled|samAccountName|securityEnabled = $ONPREM"
  case "$ONPREM" in
    True\|*|true\|*)
      ok "AD-synced -- the app can emit sam_account_name, so policy.csv keeps 'g, $GROUP, role:admin'"
      ;;
    *)
      no "NOT AD-synced -- Entra will emit the GUID, so policy.csv must read 'g, $GID, role:admin'"
      ;;
  esac
else
  no "$GROUP did not resolve in Entra (needs Group.Read.All to list; not proof of absence)"
fi

# --------------------------------------------- gate 5: is the operator in that group
say "5. Is the signed-in user a member of that group"
if [ -n "${GID:-}" ]; then
  MEM=$(az rest --method POST --url "https://graph.microsoft.com/v1.0/me/checkMemberGroups" \
        --headers 'Content-Type=application/json' \
        --body "{\"groupIds\":[\"$GID\"]}" -o json 2>/dev/null | grep -c "$GID") || MEM=0
  [ "$MEM" -ge 1 ] && ok "yes -- the first login will land on role:admin" \
                   || no "no -- login would succeed and then show an empty Argo"
else
  huh "skipped, group id unknown"
fi

# ----------------------- gate 6: can a human write the client secret to Secrets Mgr
say "6. Can a human store the client secret (the 2026-08-13 blocker)"
if [ -z "$AWS_PROFILE_ARG" ]; then
  huh "no --aws-profile given, skipped"
  val "re-run with: $0 $BR --aws-profile <the profile for $BR>"
elif ! command -v aws >/dev/null 2>&1; then
  huh "aws not on PATH"
else
  ENVPATH="op-usxpress-${BR#op-}/argocd/entra_oidc_client_secret"
  D=$(aws secretsmanager describe-secret --profile "$AWS_PROFILE_ARG" \
        --secret-id "$ENVPATH" 2>&1) || D="$D"
  case "$D" in
    *AccessDenied*)      no "AccessDenied on describe-secret -- same gap as RisingWave QA hit" ;;
    *ResourceNotFound*)  ok "reachable; secret does not exist yet (expected -- it is created later)" ;;
    *\"ARN\"*)           ok "secret already exists and is readable" ;;
    *)                   huh "unexpected: $(printf '%s' "$D" | head -1)" ;;
  esac
  val "path checked: $ENVPATH  (profile $AWS_PROFILE_ARG)"
fi

# ------------------------------------------------------------------------- summary
say "Summary for $BR"
val "callback to register : $CALLBACK"
val "PASS $pass   FAIL $fail   UNKNOWN $unk"
if [ "$fail" -eq 0 ] && [ "$unk" -eq 0 ]; then
  printf '\n   \033[32mAll gates clear -- the Entra OIDC route is buildable.\033[0m\n'
else
  printf '\n   \033[33mResolve the FAIL/???? rows above before building.\033[0m\n'
fi
printf '\n   Nothing was created or changed by this script.\n\n'

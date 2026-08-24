#!/usr/bin/env bash
# INFRA-1639 step 3 -- the Identity Center side of Argo CD SSO, as far as the API allows.
#
# WHAT THE CLI CAN DO (this script): require assignment, assign the usx-cloud-admin
# GROUP to an application the CONSOLE created, and read back what exists.
#
# WHAT THE CLI CANNOT DO -- verified 2026-08-24 against aws-cli 2.33.19:
#   * CREATE the application. create-application refuses the SAML provider outright:
#       ValidationException: The application provider with arn
#       'arn:aws:sso::aws:applicationProvider/app-50e590700beb5208' is not supported
#       for this action.
#     (note it resolves custom-saml to an internal id before refusing). That API is
#     for OAuth / trusted-identity-propagation providers only -- `custom` is OAUTH,
#     `custom-saml` is not creatable.
#   * ACS URL / SAML audience  -- update-application carries only Name, Description,
#     Status, PortalOptions. put-application-authentication-method's union has ONLY
#     `Iam` (no `Saml`); the skeleton is not truncating -- put-application-grant
#     correctly shows all four of its union members.
#   * attribute mappings       -- NO operation with 'attribute' or 'mapping' exists
#     in sso-admin at all, so ${user:groups} cannot be set through the API.
#   * the IdP metadata XML     -- no operation returns it.
# Terraform's aws_ssoadmin_application wraps this same API, so it does not help.
#
# Those three are console-only. This script does the rest and then VERIFIES the
# console work, which is the half that matters: a mistyped audience fails at login
# with an error about the assertion, not about the URL.
#
#   PROFILE=usx-mgmt scripts/idc-argocd-app.sh              # dry run
#   PROFILE=usx-mgmt scripts/idc-argocd-app.sh --assign     # assign the group (app must exist)
#   PROFILE=usx-mgmt scripts/idc-argocd-app.sh --verify     # read back the console work
set -euo pipefail

PROFILE="${PROFILE:-${AWS_PROFILE:-}}"
REGION="${REGION:-us-east-1}"
INSTANCE_ARN="${INSTANCE_ARN:-arn:aws:sso:::instance/ssoins-7223eb10c0b8ac39}"
IDENTITY_STORE_ID="${IDENTITY_STORE_ID:-d-90676260a8}"
GROUP="${GROUP:-usx-cloud-admin}"
APP_NAME="${APP_NAME:-Argo CD (op-usxpress-dev)}"
ARGOCD_URL="${ARGOCD_URL:-https://argocd.op-dev.usxpress.io}"
CALLBACK="$ARGOCD_URL/api/dex/callback"
MODE="dry"

while [ $# -gt 0 ]; do
  case "$1" in
    --go|--assign) MODE="assign"; shift ;;
    --verify) MODE="verify"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$PROFILE" ] || { echo "!! set PROFILE (CLAUDE.md rule 2). e.g. PROFILE=usx-mgmt $0" >&2; exit 2; }
command -v jq >/dev/null || { echo "!! jq not on PATH" >&2; exit 2; }
AWS() { aws --profile "$PROFILE" --region "$REGION" "$@"; }

ACCT=$(AWS sts get-caller-identity --query Account --output text)
echo "== Identity Center: $INSTANCE_ARN ($REGION)"
echo "   profile $PROFILE  account $ACCT  mode $MODE"
# The instance is owned by the management account. A member-account credential can
# LIST the instance but not administer it, so prove the write path before acting.
AWS sso-admin list-applications --instance-arn "$INSTANCE_ARN" --max-results 1 >/dev/null 2>&1 || {
  echo "!! cannot administer this instance from account $ACCT." >&2
  echo "   sso-admin list-instances answers from member accounts and proves nothing." >&2
  exit 1; }

GROUP_ID=$(AWS identitystore list-groups --identity-store-id "$IDENTITY_STORE_ID" \
             --query "Groups[?DisplayName=='$GROUP'].GroupId" --output text)
[ -n "$GROUP_ID" ] && [ "$GROUP_ID" != "None" ] || {
  echo "!! group '$GROUP' not in identity store $IDENTITY_STORE_ID" >&2; exit 1; }
echo "   group $GROUP -> $GROUP_ID"

APP_ARN=$(AWS sso-admin list-applications --instance-arn "$INSTANCE_ARN" \
            --query "Applications[?Name=='$APP_NAME'].ApplicationArn" --output text)

if [ "$MODE" = "dry" ]; then
  echo
  if [ -n "$APP_ARN" ] && [ "$APP_ARN" != "None" ]; then
    echo "   application EXISTS: $APP_ARN"
    echo "   --assign would set assignment-required and assign $GROUP."
  else
    echo "   application does NOT exist, and the CLI CANNOT create it."
    echo "   create-application refuses the SAML provider:"
    echo "     ValidationException: The application provider with arn"
    echo "     'arn:aws:sso::aws:applicationProvider/app-50e590700beb5208' is not"
    echo "     supported for this action."
    echo "   That API covers OAuth / trusted-identity-propagation providers only."
  fi
  cat <<PLAN

  IN THE CONSOLE (Identity Center -> Applications -> Customer managed):

    1. Add application -> "I have an application I want to set up"
       -> SAML 2.0 -> Next
       Display name: $APP_NAME

    2. Application metadata -> "Manually type your metadata values":
         Application ACS URL        $CALLBACK
         Application SAML audience  $CALLBACK
       Identical, no trailing slash. Dex uses the callback as entityIssuer, so a
       mismatch fails at login with an error about the assertion, not the URL.

    3. Actions -> Edit attribute mappings:
         Subject  \${user:email}   emailAddress
         email    \${user:email}   basic
         groups   \${user:groups}  basic
       If groups cannot be mapped to NAMES, stop and say so -- configs.rbac maps
       "$GROUP" and GUIDs will authenticate fine and authorise nothing.

    4. Download the IAM Identity Center SAML metadata file (XML).

  THEN, back on the CLI:

    PROFILE=$PROFILE $0 --assign     # assignment-required + assign $GROUP
    PROFILE=$PROFILE $0 --verify

PLAN
  exit 0
fi

if [ "$MODE" = "assign" ]; then
  [ -n "$APP_ARN" ] && [ "$APP_ARN" != "None" ] || {
    echo "!! no application named '$APP_NAME'." >&2
    echo "   The CLI cannot create it -- create it in the console first (run with" >&2
    echo "   no arguments to print the exact steps)." >&2
    exit 1; }
  echo "   application: $APP_ARN"

  # Assignment required, so the app is not visible to the whole directory.
  AWS sso-admin put-application-assignment-configuration \
    --application-arn "$APP_ARN" --assignment-required
  echo "   assignment required: yes"

  if AWS sso-admin list-application-assignments --application-arn "$APP_ARN" \
       --query "ApplicationAssignments[?PrincipalId=='$GROUP_ID']" --output text | grep -q .; then
    echo "   $GROUP already assigned"
  else
    AWS sso-admin create-application-assignment \
      --application-arn "$APP_ARN" --principal-id "$GROUP_ID" --principal-type GROUP
    echo "   assigned $GROUP"
  fi
  echo
  echo "   Next: PROFILE=$PROFILE $0 --verify"
  exit 0
fi

# ---- verify -----------------------------------------------------------------
[ -n "$APP_ARN" ] && [ "$APP_ARN" != "None" ] || {
  echo "!! no application named '$APP_NAME'." >&2
  echo "   Create it in the CONSOLE first -- the CLI cannot. Run with no arguments" >&2
  echo "   to print the exact steps and values." >&2
  exit 1; }
echo "   application: $APP_ARN"
AWS sso-admin describe-application --application-arn "$APP_ARN" \
  --query '{Name:Name,Status:Status,Url:PortalOptions.SignInOptions.ApplicationUrl}' --output table
echo
echo "-- assignment required? --"
AWS sso-admin get-application-assignment-configuration --application-arn "$APP_ARN" --output table
echo "-- who is assigned --"
AWS sso-admin list-application-assignments --application-arn "$APP_ARN" \
  --query 'ApplicationAssignments[].[PrincipalType,PrincipalId]' --output text \
  | while read -r ptype pid; do
      name="?"
      [ "$ptype" = "GROUP" ] && name=$(AWS identitystore describe-group \
        --identity-store-id "$IDENTITY_STORE_ID" --group-id "$pid" \
        --query DisplayName --output text 2>/dev/null || echo "?")
      printf '   %-6s %s  %s\n' "$ptype" "$pid" "$name"
    done
echo
echo "-- authentication methods (SAML config is NOT exposed here; empty is expected) --"
AWS sso-admin list-application-authentication-methods --application-arn "$APP_ARN" --output json | jq -c .
echo
echo "!! The ACS URL, SAML audience and attribute mappings CANNOT be read back through"
echo "   this API. Verify them by LOGGING IN -- that is the only check that exists:"
echo "     $ARGOCD_URL   ->  expect to land with applications visible, not an empty page"
echo "   An empty page after a successful login means the groups claim did not arrive"
echo "   or does not match configs.rbac (g, $GROUP, role:admin)."

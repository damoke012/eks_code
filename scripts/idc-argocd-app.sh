#!/usr/bin/env bash
# INFRA-1639 step 3 -- the Identity Center side of Argo CD SSO, as far as the API allows.
#
# WHAT THE CLI CAN DO (this script): create the custom-saml application, require
# assignment, assign the usx-cloud-admin GROUP, and read back what exists.
#
# WHAT THE CLI CANNOT DO -- verified 2026-08-24 against aws-cli 2.33.19:
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
#   PROFILE=usx-mgmt scripts/idc-argocd-app.sh --go         # create + assign
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
    --go) MODE="go"; shift ;;
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
    echo "   --go would be a no-op for creation."
  else
    echo "   application does NOT exist. --go would run:"
  fi
  cat <<PLAN

  aws sso-admin create-application --profile $PROFILE --region $REGION \\
    --instance-arn $INSTANCE_ARN \\
    --application-provider-arn arn:aws:sso::aws:applicationProvider/custom-saml \\
    --name "$APP_NAME" \\
    --description "Argo CD on op-usxpress-dev. INFRA-1639." \\
    --portal-options '{"SignInOptions":{"Origin":"APPLICATION","ApplicationUrl":"$ARGOCD_URL"},"Visibility":"ENABLED"}' \\
    --status ENABLED

  aws sso-admin put-application-assignment-configuration --profile $PROFILE --region $REGION \\
    --application-arn <created arn> --assignment-required

  aws sso-admin create-application-assignment --profile $PROFILE --region $REGION \\
    --application-arn <created arn> --principal-id $GROUP_ID --principal-type GROUP

PLAN
  echo "  Then, IN THE CONSOLE (no API exists for these):"
  echo "    1. Application metadata -> 'Manually type your metadata values':"
  echo "         Application ACS URL        $CALLBACK"
  echo "         Application SAML audience  $CALLBACK"
  echo "       Identical, no trailing slash. Dex uses the callback as entityIssuer."
  echo "    2. Actions -> Edit attribute mappings:"
  echo '         Subject  ${user:email}   emailAddress'
  echo '         email    ${user:email}   basic'
  echo '         groups   ${user:groups}  basic'
  echo "    3. Download the IAM Identity Center SAML metadata file (XML)."
  echo
  echo "  Then: PROFILE=$PROFILE $0 --verify"
  exit 0
fi

if [ "$MODE" = "go" ]; then
  if [ -n "$APP_ARN" ] && [ "$APP_ARN" != "None" ]; then
    echo "   application already exists, not creating: $APP_ARN"
  else
    echo "   creating application..."
    APP_ARN=$(AWS sso-admin create-application \
      --instance-arn "$INSTANCE_ARN" \
      --application-provider-arn arn:aws:sso::aws:applicationProvider/custom-saml \
      --name "$APP_NAME" \
      --description "Argo CD on op-usxpress-dev. INFRA-1639." \
      --portal-options "{\"SignInOptions\":{\"Origin\":\"APPLICATION\",\"ApplicationUrl\":\"$ARGOCD_URL\"},\"Visibility\":\"ENABLED\"}" \
      --status ENABLED --query ApplicationArn --output text)
    echo "   created: $APP_ARN"
  fi

  # Assignment required, so only the assigned group can reach it. Without this the
  # application is visible to everyone in the directory.
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
  echo "   NOW THE CONSOLE. Re-run with --dry to reprint the exact values, or see above."
  exit 0
fi

# ---- verify -----------------------------------------------------------------
[ -n "$APP_ARN" ] && [ "$APP_ARN" != "None" ] || {
  echo "!! no application named '$APP_NAME' -- run --go first" >&2; exit 1; }
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

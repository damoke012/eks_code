#!/usr/bin/env bash
# INFRA-1639 -- let a human write the platform secrets their cluster depends on.
#
# op-qa-platform-admin can READ nothing and WRITE nothing in Secrets Manager on
# op-usxpress-qa/*. ESO reads those paths through the cluster's IRSA role, so every
# secret is invisible and unrotatable to the person who owns the platform. Recorded
# as the "blocker for next time" on 2026-08-13; confirmed again 2026-08-25 with
# AccessDeniedException on secretsmanager:CreateSecret for
# op-usxpress-qa/platform/argocd/azure-ad.
#
# TRAP: put-inline-policy-to-permission-set REPLACES the whole inline policy. This
# reads the current one, merges, and shows the result before anything is written.
# A blind put here would silently drop whatever else the permission set grants.
#
#   scripts/idc-grant-secretsmanager.sh op-qa            # show + dry run
#   scripts/idc-grant-secretsmanager.sh op-qa --apply
set -uo pipefail
BR="${1:-}"; APPLY="${2:-}"
PROFILE="${PROFILE:-usx-mgmt}"
INSTANCE_ARN="arn:aws:sso:::instance/ssoins-7223eb10c0b8ac39"
REGION="us-east-1"          # Identity Center lives here; the SECRETS are us-east-2

case "$BR" in
  op-qa)   PS_NAME="op-qa-platform-admin";   ACCOUNT=527101283767; SM_REGION=us-east-2 ;;
  op-dev)  PS_NAME="op-dev-platform-admin";  ACCOUNT=700736442855; SM_REGION=us-east-2 ;;
  op-prod) PS_NAME="op-prod-platform-admin"; ACCOUNT=937464026810; SM_REGION=us-east-2
           if [ "$APPLY" = "--apply" ] && [ "${ALLOW_PROD_WRITE:-}" != "yes" ]; then
             echo "!! op-prod is PRODUCTION. Re-run as:" >&2
             echo "   ALLOW_PROD_WRITE=yes $0 op-prod --apply" >&2; exit 3
           fi ;;
  *) echo "!! usage: $0 <op-dev|op-qa|op-prod> [--apply]" >&2; exit 2 ;;
esac
CLUSTER="op-usxpress-${BR#op-}"
RES="arn:aws:secretsmanager:$SM_REGION:$ACCOUNT:secret:$CLUSTER/*"

command -v aws >/dev/null 2>&1 || { echo "!! aws not on PATH" >&2; exit 2; }
ACCT=$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text 2>&1)
case "$ACCT" in
  *"SSO session"*|*"Token has expired"*)
    echo "!! profile '$PROFILE' has an expired SSO session. Run: aws sso login --profile $PROFILE" >&2; exit 2 ;;
esac
echo "== management account $ACCT (profile $PROFILE), permission set $PS_NAME"

PS_ARN=""
NEXT=""
while : ; do
  if [ -z "$NEXT" ]; then
    OUT=$(aws sso-admin list-permission-sets --profile "$PROFILE" --region "$REGION" \
            --instance-arn "$INSTANCE_ARN" --output json 2>&1) || { echo "$OUT" >&2; exit 1; }
  else
    OUT=$(aws sso-admin list-permission-sets --profile "$PROFILE" --region "$REGION" \
            --instance-arn "$INSTANCE_ARN" --next-token "$NEXT" --output json 2>&1) || { echo "$OUT" >&2; exit 1; }
  fi
  for arn in $(printf '%s' "$OUT" | python3 -c 'import sys,json; print(" ".join(json.load(sys.stdin).get("PermissionSets",[])))'); do
    n=$(aws sso-admin describe-permission-set --profile "$PROFILE" --region "$REGION" \
          --instance-arn "$INSTANCE_ARN" --permission-set-arn "$arn" \
          --query 'PermissionSet.Name' --output text 2>/dev/null)
    [ "$n" = "$PS_NAME" ] && { PS_ARN="$arn"; break; }
  done
  [ -n "$PS_ARN" ] && break
  NEXT=$(printf '%s' "$OUT" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("NextToken",""))')
  [ -n "$NEXT" ] || break
done
[ -n "$PS_ARN" ] || { echo "!! no permission set named $PS_NAME" >&2; exit 1; }
echo "   $PS_ARN"

CURRENT=$(aws sso-admin get-inline-policy-for-permission-set --profile "$PROFILE" --region "$REGION" \
            --instance-arn "$INSTANCE_ARN" --permission-set-arn "$PS_ARN" \
            --query InlinePolicy --output text 2>/dev/null)
[ "$CURRENT" = "None" ] && CURRENT=""
echo "== current inline policy: ${CURRENT:+$(printf '%s' "$CURRENT" | wc -c) bytes}${CURRENT:-<empty>}"

MERGED=$(CURRENT="$CURRENT" RES="$RES" python3 <<'PY'
import json, os
cur, res = os.environ["CURRENT"], os.environ["RES"]
doc = json.loads(cur) if cur.strip() else {"Version": "2012-10-17", "Statement": []}
doc.setdefault("Statement", [])
if isinstance(doc["Statement"], dict): doc["Statement"] = [doc["Statement"]]
sid = "PlatformSecretsReadWrite"
# Idempotent: replace our own statement, never append a second copy, and never
# touch any statement this permission set already had.
doc["Statement"] = [s for s in doc["Statement"] if s.get("Sid") != sid]
doc["Statement"].append({
    "Sid": sid,
    "Effect": "Allow",
    "Action": [
        "secretsmanager:DescribeSecret",
        "secretsmanager:GetSecretValue",
        "secretsmanager:PutSecretValue",
        "secretsmanager:CreateSecret",
        "secretsmanager:ListSecretVersionIds",
        "secretsmanager:TagResource",
    ],
    "Resource": res,
})
print(json.dumps(doc, indent=2))
PY
) || exit 1

echo "== merged policy to be written"
printf '%s\n' "$MERGED" | sed 's/^/   /'

if [ "$APPLY" != "--apply" ]; then
  echo
  echo "   DRY RUN -- nothing written. Re-run with --apply"
  exit 0
fi

aws sso-admin put-inline-policy-to-permission-set --profile "$PROFILE" --region "$REGION" \
  --instance-arn "$INSTANCE_ARN" --permission-set-arn "$PS_ARN" \
  --inline-policy "$MERGED" || exit 1
echo "   written"

# A permission set change does nothing until it is re-provisioned to the account.
aws sso-admin provision-permission-set --profile "$PROFILE" --region "$REGION" \
  --instance-arn "$INSTANCE_ARN" --permission-set-arn "$PS_ARN" \
  --target-type AWS_ACCOUNT --target-id "$ACCOUNT" \
  --query 'PermissionSetProvisioningStatus.Status' --output text || exit 1
echo
echo "   Re-provisioned to $ACCOUNT. Your existing session carries the OLD policy --"
echo "   run 'aws sso login --profile <the $BR profile>' again before retrying."

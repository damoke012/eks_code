#!/usr/bin/env bash
# Who is assigned the usx-on-prem-admins permission set, on prod and on QA?
# READ ONLY. It makes no write call, and PRINTS the grant command rather than
# running it -- an Identity Center assignment hands out cluster-admin on a
# production cluster and is not this repo's to make.
#
#   scripts/check-onprem-admin-assignment.sh
#
# WHY
#   INFRA-1661 landed the apiserver webhook flags on op-usxpress-prod
#   2026-10-27 and prod's aws-auth maps
#     arn:aws:iam::937464026810:role/AWSReservedSSO_usx-on-prem-admins_837df2a43495aaf1
#   That role EXISTS in the account. The login still fails with
#     ForbiddenException ... GetRoleCredentials: No access
#   which is Identity Center saying "you are not assigned", not the cluster
#   saying "you are not authorised". The two are indistinguishable from the
#   kubectl side, so measure them here instead of guessing.
set -uo pipefail

MGMT_PROFILE=${MGMT_PROFILE:-usx-mgmt}
PS_NAME=${PS_NAME:-usx-on-prem-admins}
PROD=937464026810
QA=527101283767

say() { printf '%s\n' "$*"; }
die() { say "STOPPED - $*"; exit 1; }

aws --profile "$MGMT_PROFILE" sts get-caller-identity >/dev/null 2>&1 \
  || die "no live session on '$MGMT_PROFILE' (the management account).
   Identity Center assignments live there, not in the member accounts:
     aws sso login --profile $MGMT_PROFILE"

# Extract by PATTERN, not by position. `--query ... --output text` returned
# the ARN followed by a line reading "None" on 2026-10-27, and the whole
# two-line string was then passed to --instance-arn, which failed the service's
# regex. The value looked right in the output and was wrong in the variable.
RAW=$(aws --profile "$MGMT_PROFILE" sso-admin list-instances --output json 2>&1)
INST=$(printf '%s' "$RAW" | grep -oE 'arn:aws[a-z-]*:sso:::instance/(sso)?ins-[A-Za-z0-9.-]{16}' | head -1)
IDS=$(printf '%s' "$RAW" | grep -oE '"IdentityStoreId"[^"]*"[^"]+"' | grep -oE 'd-[a-z0-9]+' | head -1)
[ -n "$INST" ] || die "could not read an Identity Center instance ARN from '$MGMT_PROFILE'.
   The API said: $(printf '%s' "$RAW" | tr -s ' \n' ' ' | head -c 200)"
[ -n "$IDS" ] || die "found instance $INST but no IdentityStoreId beside it"
say "instance:        $INST"
say "identity store:  $IDS"

# --- find the permission set by NAME ----------------------------------------
# The ARN is opaque, so every set has to be described. There is no lookup by
# name in this API; a hardcoded ARN here would rot the first time the set is
# recreated.
PSARN=""; SCANNED=0; NAMES=""
PSLIST=$(aws --profile "$MGMT_PROFILE" sso-admin list-permission-sets \
           --instance-arn "$INST" --output json 2>&1 \
         | grep -oE 'arn:aws[a-z-]*:sso:::permissionSet/[A-Za-z0-9/-]+')
[ -n "$PSLIST" ] || die "listed NO permission sets on $INST.
   That is a permissions answer, not an empty directory -- the account would
   need sso-admin read access. The API said:
   $(aws --profile "$MGMT_PROFILE" sso-admin list-permission-sets --instance-arn "$INST" 2>&1 | tr -s ' \n' ' ' | head -c 200)"
for A in $PSLIST; do
  SCANNED=$((SCANNED+1))
  N=$(aws --profile "$MGMT_PROFILE" sso-admin describe-permission-set \
        --instance-arn "$INST" --permission-set-arn "$A" \
        --query 'PermissionSet.Name' --output text 2>/dev/null)
  NAMES="${NAMES}${NAMES:+ }$N"
  [ "$N" = "$PS_NAME" ] && { PSARN="$A"; break; }
done
# "Not found" after scanning zero sets and after scanning forty are different
# claims. Say which one this is.
[ -n "$PSARN" ] || die "no permission set named '$PS_NAME' among the $SCANNED scanned.
   What is there: $NAMES"
say "permission set:  $PS_NAME"
say "                 $PSARN"

# --- who is assigned, per account -------------------------------------------
principal_name() {
  case "$1" in
    GROUP) aws --profile "$MGMT_PROFILE" identitystore describe-group \
             --identity-store-id "$IDS" --group-id "$2" \
             --query 'DisplayName' --output text 2>/dev/null ;;
    USER)  aws --profile "$MGMT_PROFILE" identitystore describe-user \
             --identity-store-id "$IDS" --user-id "$2" \
             --query 'UserName' --output text 2>/dev/null ;;
  esac
}

for ACCT in "$PROD" "$QA"; do
  [ "$ACCT" = "$PROD" ] && LABEL="prod op-usxpress-prod" || LABEL="qa   op-usxpress-qa"
  say ""
  say "== $LABEL  ($ACCT)"
  ROWS=$(aws --profile "$MGMT_PROFILE" sso-admin list-account-assignments \
          --instance-arn "$INST" --account-id "$ACCT" --permission-set-arn "$PSARN" \
          --query 'AccountAssignments[].[PrincipalType,PrincipalId]' --output text 2>&1)
  if [ -z "$ROWS" ]; then
    say "   NOBODY is assigned $PS_NAME here."
  else
    printf '%s\n' "$ROWS" | while read -r T ID; do
      [ -n "$T" ] || continue
      say "   $T  $(principal_name "$T" "$ID")  ($ID)"
    done
  fi
done

say ""
say "== the grant, IF prod is missing one QA has"
say "Read the two lists above first. If QA's access comes from a GROUP, the fix"
say "is to assign that same group on prod -- not to add a person, which creates"
say "an exception nobody will remember to remove."
say ""
say "  aws --profile $MGMT_PROFILE sso-admin create-account-assignment \\"
say "    --instance-arn $INST \\"
say "    --permission-set-arn $PSARN \\"
say "    --target-id $PROD --target-type AWS_ACCOUNT \\"
say "    --principal-type GROUP --principal-id <the group id printed above>"
say ""
say "NOT RUN. That command hands cluster-admin on a production cluster to"
say "everyone in the group, and it is an access decision, not a deployment step."

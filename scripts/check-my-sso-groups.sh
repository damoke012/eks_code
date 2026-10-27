#!/usr/bin/env bash
# Which Identity Center groups is a user in?  READ ONLY.
#
#   scripts/check-my-sso-groups.sh                      # defaults to doke@usxpress.com
#   scripts/check-my-sso-groups.sh someone@usxpress.com
#
# WHY
#   op-usxpress-prod's aws-auth maps AWSReservedSSO_usx-on-prem-admins_*, that
#   permission set IS assigned on 937464026810, and the assignment is to the
#   GROUP usx-aws-admin. A login still fails with GetRoleCredentials
#   ForbiddenException, which leaves exactly one question: is this user in that
#   group? Everything upstream of it has been measured.
#
#   --alternate-identifier does NOT accept shorthand (AttributePath=...): the
#   CLI rejects it with "Shorthand syntax does not support document types". It
#   needs real JSON, which is awkward enough through a paste to be worth a file.
set -uo pipefail

USER_NAME=${1:-doke@usxpress.com}
PROFILE=${MGMT_PROFILE:-usx-mgmt}
WANT_GROUP=${WANT_GROUP:-usx-aws-admin}

say() { printf '%s\n' "$*"; }
die() { say "STOPPED - $*"; exit 1; }

aws --profile "$PROFILE" sts get-caller-identity >/dev/null 2>&1 \
  || die "no live session on '$PROFILE':  aws sso login --profile $PROFILE"

RAW=$(aws --profile "$PROFILE" sso-admin list-instances --output json 2>&1)
IDS=$(printf '%s' "$RAW" | grep -oE '"IdentityStoreId"[^"]*"[^"]+"' | grep -oE 'd-[a-z0-9]+' | head -1)
[ -n "$IDS" ] || die "could not read the identity store id: $(printf '%s' "$RAW" | tr -s ' \n' ' ' | head -c 160)"
say "identity store:  $IDS"

# --- the user id ------------------------------------------------------------
UUID_RE='[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}'
UOUT=$(aws --profile "$PROFILE" identitystore get-user-id --identity-store-id "$IDS" \
        --alternate-identifier "{\"UniqueAttribute\":{\"AttributePath\":\"userName\",\"AttributeValue\":\"$USER_NAME\"}}" \
        --query UserId --output text 2>&1)
USER_ID=$(printf '%s' "$UOUT" | grep -oE "$UUID_RE" | head -1)

if [ -z "$USER_ID" ]; then
  # The username may not be the email address. Scan rather than conclude --
  # "no such user" and "the username is spelled differently" need different
  # fixes and look identical from a failed lookup.
  say "get-user-id did not resolve '$USER_NAME': $(printf '%s' "$UOUT" | tr -s ' \n' ' ' | head -c 120)"
  say "scanning the directory for a near match..."
  MATCH=$(aws --profile "$PROFILE" identitystore list-users --identity-store-id "$IDS" \
           --query 'Users[].[UserId,UserName]' --output text 2>/dev/null \
         | grep -i "${USER_NAME%%@*}" | head -5)
  [ -n "$MATCH" ] || die "no user in the directory matches '${USER_NAME%%@*}'"
  say "candidates:"
  printf '%s\n' "$MATCH" | while read -r I N; do say "   $N  ($I)"; done
  USER_ID=$(printf '%s\n' "$MATCH" | head -1 | awk '{print $1}')
  USER_NAME=$(printf '%s\n' "$MATCH" | head -1 | awk '{print $2}')
  say "using the first: $USER_NAME"
fi
say "user:            $USER_NAME  ($USER_ID)"

# --- the groups -------------------------------------------------------------
say ""
say "== groups"
GIDS=$(aws --profile "$PROFILE" identitystore list-group-memberships-for-member \
        --identity-store-id "$IDS" --member-id "UserId=$USER_ID" \
        --query 'GroupMemberships[].GroupId' --output text 2>&1)
case "$GIDS" in
  *error*|*Error*) die "could not list memberships: $(printf '%s' "$GIDS" | tr -s ' \n' ' ' | head -c 160)" ;;
esac
[ -n "$GIDS" ] || { say "   NONE. This user is in no Identity Center group at all."; }

FOUND=no; COUNT=0
for G in $GIDS; do
  N=$(aws --profile "$PROFILE" identitystore describe-group --identity-store-id "$IDS" \
        --group-id "$G" --query DisplayName --output text 2>/dev/null)
  COUNT=$((COUNT+1))
  MARK=""
  [ "$N" = "$WANT_GROUP" ] && { FOUND=yes; MARK="   <-- grants usx-on-prem-admins on prod"; }
  say "   $N$MARK"
done

say ""
if [ "$FOUND" = yes ]; then
  say "IN '$WANT_GROUP'. So group membership is NOT the blocker, and the"
  say "ForbiddenException has another cause -- an SSO session predating the"
  say "membership is the first thing to rule out:  aws sso logout, then log in."
else
  say "NOT in '$WANT_GROUP' (checked $COUNT group(s))."
  say "That is the whole reason prod's SSO login fails. The permission set is"
  say "assigned on 937464026810 already -- to that group, and not to this user."
  say ""
  say "Two ways to fix it, and they are not equivalent:"
  say "  1. Join $WANT_GROUP. One change, but it is an AWS-admin group and the"
  say "     grant would be much wider than cluster access."
  say "  2. Mirror QA: a op-prod-platform-admin permission set assigned to the"
  say "     on-prem platform group, added to prod's aws-auth beside the existing"
  say "     entry. More work, matches what QA already proves, and keeps on-prem"
  say "     cluster access separate from AWS account administration."
fi

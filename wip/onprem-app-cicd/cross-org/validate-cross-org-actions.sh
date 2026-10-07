#!/usr/bin/env bash
# Can an app repo in the USX org call a reusable workflow published in variant-inc?
#
# READ ONLY. Every call is a GET. Nothing is created, changed or deleted.
#
# Run on WSL, where the corp GHE remotes and `gh` auth live. Never from a codespace.
#
#   bash validate-cross-org-actions.sh <USX_ORG> [USX_REPO]
#
# The API can prove three of the four unknowns. It CANNOT prove the fourth -- that a
# cross-org `uses:` actually resolves at run time -- because only a real run proves that.
# This script says exactly which ones it settled and which one is still open, and it
# never reports an unchecked thing as a pass.
set -uo pipefail

USX_ORG="${1:-}"
USX_REPO="${2:-}"
PLATFORM_ORG="variant-inc"
WF_REPO="usx-cicd-workflows"     # the repo that will hold the reusable workflow
AWS_ACCOUNT="064859874041"

RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; OFF=$'\033[0m'
pass() { printf '%sPASS%s %s\n' "$GRN" "$OFF" "$*"; }
fail() { printf '%sFAIL%s %s\n' "$RED" "$OFF" "$*"; }
open_() { printf '%sOPEN%s %s\n' "$YEL" "$OFF" "$*"; }

[ -z "$USX_ORG" ] && { echo "usage: $0 <USX_ORG> [USX_REPO]"; echo; echo "Find the org name with:  gh api /user/orgs --jq '.[].login'"; exit 2; }

command -v gh >/dev/null || { fail "gh not installed -- cannot check anything"; exit 2; }
if ! gh auth status >/dev/null 2>&1; then
  fail "gh is not authenticated. Run: gh auth login"; exit 2
fi
echo "authenticated as: $(gh api /user --jq .login 2>/dev/null || echo UNKNOWN)"
echo

echo "=== 0. Which orgs can this account even see? ==="
gh api /user/orgs --jq '.[].login' 2>/dev/null | sed 's/^/  /' || echo "  (could not list)"
echo "  (an org missing here may still exist -- it means THIS account cannot see it,"
echo "   which is itself a finding about who can run the setup)"
echo

echo "=== 1. Do both orgs exist and are they in the same enterprise? ==="
for O in "$PLATFORM_ORG" "$USX_ORG"; do
  R=$(gh api "/orgs/$O" 2>/dev/null)
  if [ -z "$R" ]; then fail "$O -- not visible to this account"; continue; fi
  ENT=$(printf '%s' "$R" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("business_plus") and "business_plus" or "", d.get("plan",{}).get("name","?"))' 2>/dev/null)
  pass "$O exists (billing plan: $ENT)"
  echo "    ^ plan name only. 'enterprise' here is the BILLING TIER and is NOT evidence"
  echo "      that the two orgs belong to the same enterprise ACCOUNT."
done
echo "  NOTE: the REST API does not expose enterprise membership to a non-admin."
echo "  The decisive check is step 2 -- if access_level can be set to 'enterprise',"
echo "  they are in one. If the only options that stick are none/organization, they are not."
echo

echo "=== 2. THE DECIDING CHECK -- the workflow repo's Actions access level ==="
ACC=$(gh api "/repos/$PLATFORM_ORG/$WF_REPO/actions/permissions/access" 2>/dev/null)
# gh writes the error BODY to stdout, so a 404 leaves ACC non-empty. Treat any
# payload carrying "status" as an error, never as a reading.
if [ -z "$ACC" ] || printf '%s' "$ACC" | grep -q '"status"'; then
  open_ "$PLATFORM_ORG/$WF_REPO does not exist yet (expected -- we have not created it)."
  echo "  After creating it, set this and re-run:"
  echo "    gh api -X PUT /repos/$PLATFORM_ORG/$WF_REPO/actions/permissions/access \\"
  echo "       -f access_level=enterprise"
  echo "  access_level values: none | organization | enterprise"
  echo "    organization -> only variant-inc repos may call it"
  echo "    enterprise   -> any repo in the SAME enterprise may call it  <-- what we need"
  echo "  If 'enterprise' is rejected, the orgs are not in one enterprise and the"
  echo "  fallback is to make $WF_REPO PUBLIC. It holds workflow logic and no secrets;"
  echo "  the AWS trust policy is what grants anything."
else
  LVL=$(printf '%s' "$ACC" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_level","?"))')
  case "$LVL" in
    enterprise) pass "access_level=enterprise -- a repo in another org of the same enterprise CAN call it" ;;
    organization) fail "access_level=organization -- only $PLATFORM_ORG repos can call it. Raise to enterprise." ;;
    none) fail "access_level=none -- no other repo can call it at all." ;;
    *) open_ "access_level=$LVL -- unrecognised" ;;
  esac
  VIS=$(gh api "/repos/$PLATFORM_ORG/$WF_REPO" --jq .visibility 2>/dev/null)
  echo "  repo visibility: ${VIS:-unknown}  (public needs no access_level at all)"
fi
echo

echo "=== 3. Does the USX org allow Actions, and what can they run? ==="
P=$(gh api "/orgs/$USX_ORG/actions/permissions" 2>/dev/null)
if [ -z "$P" ] || printf '%s' "$P" | grep -q '"status"'; then
  open_ "cannot read /orgs/$USX_ORG/actions/permissions -- needs org admin. ASK, do not assume."
  printf '%s' "$P" | head -c 200; echo
  echo "  NOT MEASURED. An allowlist may or may not be in force; this run does not know."
else
  printf '%s' "$P" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("  enabled_repositories:", d.get("enabled_repositories"))
print("  allowed_actions     :", d.get("allowed_actions"))'
  AA=$(printf '%s' "$P" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("allowed_actions",""))')
  if [ "$AA" = "selected" ]; then
    echo "  allowed_actions=selected -- there is an ALLOWLIST. Our reusable workflow must be on it:"
    gh api "/orgs/$USX_ORG/actions/permissions/selected-actions" 2>/dev/null | sed 's/^/    /'
    fail "an allowlist is in force -- $PLATFORM_ORG/$WF_REPO must be added to patterns_allowed"
  elif [ -n "$AA" ]; then
    pass "allowed_actions=$AA -- no allowlist blocking us"
  fi
fi
echo

echo "=== 4. Default workflow permissions in the USX org ==="
W=$(gh api "/orgs/$USX_ORG/actions/permissions/workflow" 2>/dev/null)
if [ -z "$W" ]; then
  open_ "cannot read it -- needs org admin."
else
  printf '%s' "$W" | sed 's/^/  /'
  echo "  NOTE: id-token: write is requested per-workflow and is NOT disabled by this"
  echo "  setting. There is no org switch that turns OIDC off. Step 2 is the real risk,"
  echo "  not this one."
fi
echo

echo "=== 5. Is the AWS OIDC provider present in $AWS_ACCOUNT? ==="
if ! command -v aws >/dev/null; then
  open_ "aws CLI not installed -- not checked"
else
  ARN=$(aws iam list-open-id-connect-providers \
          --query "OpenIDConnectProviderList[?contains(Arn,'token.actions.githubusercontent.com')].Arn" \
          --output text 2>/dev/null)
  if [ -n "$ARN" ]; then pass "OIDC provider present: $ARN"
  else open_ "no GitHub OIDC provider found, or the current profile is not $AWS_ACCOUNT."
       echo "  current identity: $(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo UNKNOWN)"
  fi
fi
echo

if [ -n "$USX_REPO" ]; then
  echo "=== 6. The app repo itself ==="
  R=$(gh api "/repos/$USX_ORG/$USX_REPO" 2>/dev/null)
  if [ -z "$R" ]; then
    fail "$USX_ORG/$USX_REPO not visible to this account -- this is the access gap from the call"
  else
    printf '%s' "$R" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("  full_name :", d["full_name"])
print("  visibility:", d.get("visibility"))
print("  default_br:", d.get("default_branch"))
perm=d.get("permissions",{})
print("  our perms :", ",".join(k for k,v in perm.items() if v) or "none")'
    echo
    echo "  The OIDC sub this repo will present on its default branch:"
    DB=$(printf '%s' "$R" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("default_branch","main"))')
    echo "    repo:$USX_ORG/$USX_REPO:ref:refs/heads/$DB"
    echo "  That exact string goes in the trust policy. It is a literal match."
  fi
  echo
fi

echo "============================================================"
echo "WHAT THIS SCRIPT CANNOT SETTLE"
echo "  Whether a cross-org \`uses:\` RESOLVES AT RUN TIME. No API answers that."
echo "  The proof is one real run of the caller workflow. Until that run is green,"
echo "  the cross-org hop is UNPROVEN -- and a passing step 2 is not a substitute."
echo "============================================================"

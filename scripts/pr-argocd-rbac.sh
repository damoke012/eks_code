#!/usr/bin/env bash
# INFRA-1639 step 4 -- Argo CD RBAC, so an SSO login lands with permissions.
#
# configs.rbac is UNSET on op-dev and op-qa, so argocd-rbac-cm carries the chart
# defaults: policy.default "" and policy.csv "". A user who authenticates through
# SSO successfully therefore lands with ZERO permissions and sees an empty UI with
# access errors -- which presents as a broken login when it is RBAC.
#
# This is INERT until a provider is wired: there are no SSO users yet, admin.enabled
# stays true, and the local admin account is untouched. That is why it can land first.
#
#   scripts/pr-argocd-rbac.sh              # dry run, prints both diffs
#   scripts/pr-argocd-rbac.sh --push
set -euo pipefail

REPO="${REPO:-$HOME/pr-work/iaac-talos-flux-platform}"
PUSH="no"; ONLY=""
# An AWS Identity Center DIRECTORY group. Verified present in identity store
# d-90676260a8 on 2026-08-24.
#
# NOT onprem-platform-admins, which was the first value here and was wrong.
# That name is a KUBERNETES RBAC group invented in aws-auth: cluster access is
# granted by PERMISSION SET (the caller arrives as
# AWSReservedSSO_AWSAdministratorAccess) which aws-auth maps to that k8s group
# name. It has never existed in the directory -- `identitystore list-groups`
# returns zero matches for 'onprem' or 'platform' across the whole store.
#
# A SAML assertion carries directory groups. Same identity, different axis, so
# the two layers cannot share one name however tidy that would have been.
GROUP="${GROUP:-usx-cloud-admin}"

# Where to verify that group actually exists. Set PROFILE to check; unset skips
# with a warning rather than silently trusting the name.
IDENTITY_STORE_ID="${IDENTITY_STORE_ID:-d-90676260a8}"
IDC_REGION="${IDC_REGION:-us-east-1}"
PROFILE="${PROFILE:-${AWS_PROFILE:-}}"
while [ $# -gt 0 ]; do
  case "$1" in
    --push) PUSH="yes"; shift ;;
    --only) ONLY="$2"; shift 2 ;;
    --group) GROUP="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -d "$REPO/.git" ] || { echo "!! not a git repo: $REPO" >&2; exit 2; }
cd "$REPO"
git fetch origin

# Prove the group exists before writing a policy that maps it. The first version
# of this script mapped a name that was never in the directory, and nothing would
# have surfaced that until a real SSO login landed with no permissions.
if [ -n "$PROFILE" ]; then
  found=$(aws identitystore list-groups --profile "$PROFILE" --region "$IDC_REGION" \
            --identity-store-id "$IDENTITY_STORE_ID" \
            --query "Groups[?DisplayName=='$GROUP'].GroupId" --output text 2>&1) || true
  case "$found" in
    ""|*Denied*|*error*|*Error*)
      echo "!! '$GROUP' not found in identity store $IDENTITY_STORE_ID ($IDC_REGION)." >&2
      echo "   $(printf '%s' "$found" | head -1 | cut -c1-100)" >&2
      echo "   A policy mapping a group that does not exist produces a successful" >&2
      echo "   login with zero permissions. Refusing." >&2
      exit 1 ;;
    *) echo "   group verified: $GROUP -> $found" ;;
  esac
else
  echo "   (PROFILE unset -- NOT verifying '$GROUP' exists in the directory.)"
  echo "   Re-run as: PROFILE=usx-dev $0"
fi

clean_argocd() {
  git checkout -q HEAD -- infrastructure/argocd 2>/dev/null || true
  git clean -qfd infrastructure/argocd 2>/dev/null || true
}
trap clean_argocd EXIT

BRANCHES="op-dev op-qa"
[ -z "$ONLY" ] || BRANCHES="$ONLY"

for BR in $BRANCHES; do
  TOPIC="infra-1639-argocd-rbac-$BR"
  echo
  echo "################ $BR ################"
  clean_argocd
  git checkout -q -B "$TOPIC" "origin/$BR"
  git checkout -q "origin/$BR" -- infrastructure/argocd
  git clean -qfd infrastructure/argocd

  HR="infrastructure/argocd/helmrelease.yaml"
  [ -f "$HR" ] || { echo "!! $HR missing on $BR" >&2; exit 1; }

  if grep -qE '^      rbac:$' "$HR"; then
    echo "   configs.rbac already present, leaving alone"
  else
    [ "$(grep -cE '^      cm:$' "$HR")" -eq 1 ] \
      || { echo "!! expected exactly one '      cm:' line in $HR" >&2; exit 1; }
    python3 - "$HR" "$GROUP" <<'PY1'
import sys
path, group = sys.argv[1], sys.argv[2]
block = """      rbac:
        # INFRA-1639 step 4. Left unset, the chart defaults are policy.default ""
        # and policy.csv "" -- a user who authenticates through SSO lands with NO
        # permissions and sees an empty UI with access errors. That reads as a
        # broken login when it is authorisation, so this must land WITH the
        # provider, not after someone reports SSO "not working".
        #
        # policy.default stays "" deliberately: no implicit access for anyone who
        # merely authenticates. Access is granted per group, explicitly, below.
        policy.default: ""
        # %(group)s is an AWS Identity Center DIRECTORY group, verified present
        # in identity store d-90676260a8 on 2026-08-24.
        #
        # It is deliberately NOT onprem-platform-admins. That name is a Kubernetes
        # RBAC group invented in aws-auth -- cluster access is granted by PERMISSION
        # SET and mapped to it there, and it has never existed in the directory. A
        # SAML assertion carries directory groups, so the two layers cannot share a
        # name. Mapping the k8s name here would authenticate fine and authorise
        # nothing.
        policy.csv: |
          g, %(group)s, role:admin
        # Argo only sees groups if the provider actually emits a groups claim.
        # If logins succeed but land with no permissions, check the claim before
        # touching this file.
        scopes: "[groups]"
""" % {"group": group}
lines = open(path).readlines()
out, done = [], False
for ln in lines:
    if not done and ln.rstrip("\n") == "      cm:":
        out.append(block)
        done = True
    out.append(ln)
open(path, "w").writelines(out)
sys.exit(0 if done else 1)
PY1
    echo "   configs.rbac inserted (group: $GROUP)"
  fi

  python3 - "$HR" "$GROUP" <<'PY2'
import sys, yaml
path, group = sys.argv[1], sys.argv[2]
d = yaml.safe_load(open(path))
cfg = d["spec"]["values"]["configs"]
rbac = cfg["rbac"]
assert rbac["policy.default"] == "", repr(rbac["policy.default"])
assert ("g, %s, role:admin" % group) in rbac["policy.csv"], rbac["policy.csv"]
assert rbac["scopes"] == "[groups]", rbac["scopes"]
# the url from the earlier PR must survive this edit
assert cfg["cm"]["url"].startswith("https://argocd."), cfg["cm"].get("url")
assert cfg["cm"]["admin.enabled"] == "true", "local admin must stay until SSO is proven"
print("   parsed back:     policy.default='' | g, %s, role:admin | scopes [groups]" % group)
print("   url intact:      %s" % cfg["cm"]["url"])
PY2

  git add -A infrastructure/argocd
  echo
  echo "-------- git diff origin/$BR --------"
  git --no-pager diff --cached "origin/$BR"
  echo "-------- end --------"

  git commit -q -m "INFRA-1639: Argo CD RBAC on $BR, so SSO logins land with permissions

configs.rbac was unset, so argocd-rbac-cm carried the chart defaults: policy.default
\"\" and policy.csv \"\". A successful SSO authentication would land with zero
permissions -- an empty UI with access errors, which reads as a broken login when it
is authorisation.

Grants $GROUP role:admin -- an Identity Center DIRECTORY group, verified present in
identity store d-90676260a8. Deliberately not onprem-platform-admins: that is a
Kubernetes RBAC group invented in aws-auth, where access is granted by permission set,
and it has never existed in the directory. A SAML assertion carries directory groups,
so the two layers cannot share a name.

policy.default stays \"\" -- no implicit access for merely authenticating.

Inert today: no SSO provider is configured, no SSO users exist, admin.enabled remains
true and the local admin account is untouched. Landing it before the provider is what
stops the first SSO login looking broken." || echo "   nothing to commit"

  if [ "$PUSH" = "yes" ]; then
    git push -q -u origin "$TOPIC" --force-with-lease
    echo "   pushed $TOPIC"
    echo
    # iaac-talos-flux-platform has a branch PER CLUSTER and its default branch is op-dev, so
    # GitHub's "Create a pull request" link opens with base=op-dev. Creating it there merges a
    # change meant for one cluster into DEV. Caught on the compare page 2026-09-03, before it
    # was created; the tells are "Can't automatically merge" and an empty auto-filled body.
    echo "   Open the PR with the base pinned — do NOT use the GitHub link, it defaults to op-dev:"
    echo "     gh pr create --base $BR --head $TOPIC --fill"
  else
    echo "   committed to local $TOPIC (not pushed)"
  fi
done

echo
[ "$PUSH" = "yes" ] || cat <<'DONE'
Committed to local topic branches; NOTHING PUSHED. Read the diffs, then re-run
with --push.
DONE

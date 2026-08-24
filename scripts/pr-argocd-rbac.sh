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
# The group is the one the cluster SSO path already grants through
# aws-iam-authenticator (INFRA-1638). One group, both layers -- not a second
# access model to keep in sync.
GROUP="${GROUP:-onprem-platform-admins}"
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
        # %(group)s is the SAME group the cluster SSO path grants through
        # aws-iam-authenticator (INFRA-1638) -- one group across both layers
        # rather than a second access model to keep in sync.
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

Grants $GROUP role:admin. That is the same group the cluster SSO path already grants
through aws-iam-authenticator (INFRA-1638), so there is one group across both layers.
policy.default stays \"\" -- no implicit access for merely authenticating.

Inert today: no SSO provider is configured, no SSO users exist, admin.enabled remains
true and the local admin account is untouched. Landing it before the provider is what
stops the first SSO login looking broken." || echo "   nothing to commit"

  if [ "$PUSH" = "yes" ]; then
    git push -q -u origin "$TOPIC" --force-with-lease
    echo "   pushed $TOPIC"
  else
    echo "   committed to local $TOPIC (not pushed)"
  fi
done

echo
[ "$PUSH" = "yes" ] || cat <<'DONE'
Committed to local topic branches; NOTHING PUSHED. Read the diffs, then re-run
with --push.
DONE

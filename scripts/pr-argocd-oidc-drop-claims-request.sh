#!/usr/bin/env bash
# INFRA-1639 -- remove requestedIDTokenClaims from oidc.config.
#
# Entra issues a valid token with NO groups claim, under both ApplicationGroup and
# SecurityGroup, while: the user is in 42 security groups including the target one
# (me/getMemberGroups securityEnabledOnly), the app has groups in
# optionalClaims.idToken, and the service principal carries no claimsMappingPolicy.
#
# Everything the app registration controls is verified correct, which points at the
# request rather than the directory. requestedIDTokenClaims makes Argo send an
# OIDC `claims` request parameter; that is the pattern Argo documents for Okta, not
# for Entra, and the cloud EKS fleet's working Argo registration does not need it --
# groups reach those clusters from the manifest alone.
#
# This removes the one thing in the request that is not in the working example.
#
#   scripts/pr-argocd-oidc-drop-claims-request.sh op-dev
#   scripts/pr-argocd-oidc-drop-claims-request.sh op-dev --push
set -euo pipefail
BR="${1:-}"; PUSH="${2:-}"
REPO="${REPO:-$HOME/pr-work/iaac-talos-flux-platform}"
case "$BR" in op-dev|op-qa|op-prod) : ;; *)
  echo "!! branch must be op-dev, op-qa or op-prod (got '${BR:-}')" >&2; exit 2 ;; esac
[ -d "$REPO/.git" ] || { echo "!! not a git repo: $REPO" >&2; exit 2; }

cd "$REPO"
git fetch -q origin
TOPIC="infra-1639-argocd-oidc-claims-$BR"
git checkout -q HEAD -- infrastructure/argocd 2>/dev/null || true
git clean -qfd infrastructure/argocd 2>/dev/null || true
git checkout -q -B "$TOPIC" "origin/$BR"
git checkout -q "origin/$BR" -- infrastructure/argocd
git clean -qfd infrastructure/argocd

python3 - <<'PY'
import yaml
HR = "infrastructure/argocd/helmrelease.yaml"
lines = open(HR).readlines()

out, dropping, dropped = [], False, 0
for ln in lines:
    stripped = ln.strip()
    if stripped == "requestedIDTokenClaims:":
        dropping = True; dropped += 1; continue
    if dropping:
        # its nested block: groups: / essential: true
        if stripped in ("groups:", "essential: true"):
            dropped += 1; continue
        dropping = False
    out.append(ln)
assert dropped >= 3, "expected to drop requestedIDTokenClaims and its two nested lines, dropped %d" % dropped
open(HR, "w").writelines(out)

v = yaml.safe_load(open(HR))["spec"]["values"]
o = yaml.safe_load(v["configs"]["cm"]["oidc.config"])
assert "requestedIDTokenClaims" not in o, "still present after the edit"
# everything that must survive
assert o["clientSecret"] == "$oidc.entra.clientSecret", o.get("clientSecret")
assert o["clientID"] == "42dc0c33-4c56-47a5-b207-d119272997aa", o.get("clientID")
assert set(o["requestedScopes"]) == {"openid", "profile", "email"}, o["requestedScopes"]
assert v["dex"]["enabled"] is False
assert v["configs"]["rbac"].get("scopes") == "[groups]"
print("   removed requestedIDTokenClaims (%d lines); the rest of oidc.config intact" % dropped)
PY

echo
git --no-pager diff -- infrastructure/argocd
[ "$PUSH" = "--push" ] || { echo; echo "   DRY RUN -- re-run with --push"; exit 0; }

BODY=$(mktemp); trap 'rm -f "$BODY"' EXIT
cat > "$BODY" <<'MD'
Entra issues a valid token for this app with no `groups` claim, under both
`ApplicationGroup` and `SecurityGroup`. Ruled out by readback: the user is in 42
security groups including the one RBAC targets, `groups` is present in the app's
`optionalClaims.idToken`, and the service principal has no claims-mapping policy.

`requestedIDTokenClaims` makes Argo send an OIDC `claims` request parameter. That
is the pattern Argo documents for Okta; the cloud EKS fleet's Argo registration
gets its groups from the app manifest with no such request. Removing it takes the
request back to what is known to work in this tenant.

If groups still do not arrive after this, the cause is not in Argo's request and
the question moves to the tenant.
MD
git add infrastructure/argocd
git commit -qm "INFRA-1639: drop requestedIDTokenClaims from oidc.config

Entra returns a token with no groups claim while every app-registration field
reads correct. The claims request parameter is the one element of our config that
the working cloud-fleet example does not have."
git push -q -u origin "$TOPIC"
gh pr create --base "$BR" --head "$TOPIC" \
  --title "INFRA-1639: drop the OIDC claims request on $BR" --body-file "$BODY"

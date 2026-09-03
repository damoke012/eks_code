#!/usr/bin/env bash
# INFRA-1639 step 3, cluster side -- wire the Identity Center SAML connector into Argo.
#
# Two edits: dex.enabled false -> true, and dex.config under configs.cm. Takes the
# block produced by scripts/dex-saml-from-metadata.sh so the ssoURL and certificate
# come from the live IdP metadata, not from retyping.
#
# Nothing secret: caData is the IdP's PUBLIC signing certificate. argocd-secret is
# never touched, so op-dev's server.secretkey (from the raw install it adopted)
# survives untouched.
#
#   scripts/pr-argocd-dex-connector.sh ~/argocd-dex-saml-op-dev.yaml op-dev
#   scripts/pr-argocd-dex-connector.sh ~/argocd-dex-saml-op-dev.yaml op-dev --push
set -euo pipefail

SRC="${1:-}"; BR="${2:-}"; PUSH="${3:-}"
REPO="${REPO:-$HOME/pr-work/iaac-talos-flux-platform}"
[ -f "$SRC" ] || { echo "!! block file not found: ${SRC:-<none>}" >&2
                   echo "   generate it: scripts/dex-saml-from-metadata.sh <metadata.xml> <env>" >&2; exit 2; }
case "$BR" in
  op-dev|op-qa|op-prod) : ;;
  *) echo "!! branch must be op-dev, op-qa or op-prod (got '${BR:-}')" >&2; exit 2 ;;
esac
[ -d "$REPO/.git" ] || { echo "!! not a git repo: $REPO" >&2; exit 2; }

cd "$REPO"
git fetch origin
TOPIC="infra-1639-argocd-dex-$BR"
git checkout -q HEAD -- infrastructure/argocd 2>/dev/null || true
git clean -qfd infrastructure/argocd 2>/dev/null || true
git checkout -q -B "$TOPIC" "origin/$BR"
git checkout -q "origin/$BR" -- infrastructure/argocd
git clean -qfd infrastructure/argocd

HR="infrastructure/argocd/helmrelease.yaml"
[ -f "$HR" ] || { echo "!! $HR missing on $BR" >&2; exit 1; }

python3 - "$HR" "$SRC" "$BR" <<'PY1'
import sys, yaml
hr, src, br = sys.argv[1], sys.argv[2], sys.argv[3]

block = yaml.safe_load(open(src))
dexcfg = block["configs"]["cm"]["dex.config"]
conn = yaml.safe_load(dexcfg)["connectors"][0]["config"]
host = "argocd.%s.usxpress.io" % br
want = "https://%s/api/dex/callback" % host
assert conn["redirectURI"] == want, (conn["redirectURI"], want)
assert conn["entityIssuer"] == want, "entityIssuer must equal the SAML audience"
assert conn["groupsAttr"] == "groups", conn.get("groupsAttr")
assert conn["ssoURL"].startswith("https://portal.sso."), conn["ssoURL"]

lines = open(hr).readlines()

# 1. dex.enabled false -> true, scoped to the `    dex:` block so nothing else flips.
out, in_dex, flipped = [], False, False
for ln in lines:
    if ln.rstrip("\n") == "    dex:":
        in_dex = True
    elif in_dex and ln.strip() and not ln.startswith("      "):
        in_dex = False
    if in_dex and ln.strip() == "enabled: false":
        ln = ln.replace("false", "true"); flipped = True
    out.append(ln)
assert flipped, "did not find `enabled: false` inside the dex block"

# 2. dex.config as the first key under configs.cm, lifted verbatim from the
#    generated file -- same indentation, so no re-indenting to get wrong.
src_lines = open(src).read().splitlines(True)
start = next(i for i, l in enumerate(src_lines) if l.rstrip("\n") == "        dex.config: |")
cfg_lines = src_lines[start:]

final, done = [], False
for ln in out:
    final.append(ln)
    if not done and ln.rstrip("\n") == "      cm:":
        final.extend(cfg_lines)
        done = True
assert done, "did not find `      cm:`"
open(hr, "w").writelines(final)

# parse back
d = yaml.safe_load(open(hr))
v = d["spec"]["values"]
assert v["dex"]["enabled"] is True, v["dex"]
c2 = yaml.safe_load(v["configs"]["cm"]["dex.config"])["connectors"][0]["config"]
assert c2["ssoURL"] == conn["ssoURL"]
assert c2["caData"].startswith("-----BEGIN CERTIFICATE-----") or len(c2["caData"]) > 100
assert v["configs"]["cm"]["url"] == "https://%s" % host, v["configs"]["cm"].get("url")
assert v["configs"]["cm"]["admin.enabled"] == "true", "keep local admin until SSO is proven"
assert "usx-cloud-admin" in v["configs"]["rbac"]["policy.csv"], v["configs"]["rbac"]
print("   dex.enabled : true")
print("   ssoURL      : %s" % c2["ssoURL"])
print("   redirectURI : %s" % c2["redirectURI"])
print("   url intact  : %s" % v["configs"]["cm"]["url"])
print("   rbac intact : %s" % v["configs"]["rbac"]["policy.csv"].strip())
PY1

git add -A infrastructure/argocd
echo
echo "-------- git diff origin/$BR --------"
git --no-pager diff --cached "origin/$BR"
echo "-------- end --------"

git commit -q -m "INFRA-1639: Argo CD SSO via AWS Identity Center on $BR

Turns on Dex and adds the SAML connector for the Identity Center application
(apl-72236face0cd1203, instance ssoins-7223eb10c0b8ac39, account 660075424663),
which is ENABLED with assignment required and usx-cloud-admin assigned.

No secret involved: caData is the IdP's public signing certificate (Amazon IDAS,
valid to 2031), so this lives in git and argocd-secret is never touched --
op-dev's server.secretkey from its adopted raw install survives.

entityIssuer equals the Application SAML audience exactly; a mismatch fails at
login with an error about the assertion rather than the URL.

admin.enabled stays true so the local account remains the way back in until a
real SSO login is proven.

ACCEPTANCE is a login, not a green HelmRelease: open https://argocd.$BR.usxpress.io,
sign in via Identity Center, and land with applications visible. An empty page
means the groups claim did not arrive or does not match policy.csv."

if [ "$PUSH" = "--push" ]; then
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
  echo "   committed to local $TOPIC (not pushed). Re-run with --push as the 3rd argument."
fi

#!/usr/bin/env bash
# INFRA-1639 -- give Argo the Entra client secret, and switch oidc.config to a
# confidential client. Follows the SPA -> web client-type correction.
#
# Two edits, no new files:
#   1. admin-externalsecret.yaml gains one data entry. It already targets
#      argocd-secret with creationPolicy: Merge, so the value lands beside
#      server.secretkey without disturbing it -- which matters on op-dev, where
#      argocd-secret came from the raw install the HelmRelease adopted.
#   2. oidc.config gains clientSecret: $oidc.entra.clientSecret and loses
#      enablePKCEAuthentication. Argo resolves a leading $ against argocd-secret.
#
# The Secrets Manager path is derived from the branch. A dev path copied onto the
# QA branch is the bug family in manifests-copied-across-branches, six instances
# and counting.
#
#   scripts/pr-argocd-entra-secret.sh op-dev
#   scripts/pr-argocd-entra-secret.sh op-dev --push
set -euo pipefail
BR="${1:-}"; PUSH="${2:-}"
REPO="${REPO:-$HOME/pr-work/iaac-talos-flux-platform}"
case "$BR" in op-dev|op-qa|op-prod) : ;; *)
  echo "!! branch must be op-dev, op-qa or op-prod (got '${BR:-}')" >&2; exit 2 ;; esac
[ -d "$REPO/.git" ] || { echo "!! not a git repo: $REPO" >&2; exit 2; }

cd "$REPO"
git fetch -q origin
TOPIC="infra-1639-argocd-entra-secret-$BR"
git checkout -q HEAD -- infrastructure/argocd 2>/dev/null || true
git clean -qfd infrastructure/argocd 2>/dev/null || true
git checkout -q -B "$TOPIC" "origin/$BR"
git checkout -q "origin/$BR" -- infrastructure/argocd
git clean -qfd infrastructure/argocd

python3 - "$BR" <<'PY'
import sys, yaml
br = sys.argv[1]
cluster = "op-usxpress-%s" % br[len("op-"):]
sm_key  = "%s/platform/argocd/azure-ad" % cluster
ES = "infrastructure/argocd/admin-externalsecret.yaml"
HR = "infrastructure/argocd/helmrelease.yaml"
SECRET_KEY = "oidc.entra.clientSecret"

# ---------------------------------------------------------------- ExternalSecret
doc = yaml.safe_load(open(ES))
assert doc["kind"] == "ExternalSecret", doc.get("kind")
tgt = doc["spec"]["target"]
assert tgt["name"] == "argocd-secret", \
    "target is %r; a $-reference in argocd-cm resolves against argocd-secret" % tgt["name"]
assert tgt.get("creationPolicy") == "Merge", \
    "creationPolicy is %r, not Merge -- Owner would take over argocd-secret and " \
    "drop server.secretkey from the install this cluster adopted" % tgt.get("creationPolicy")

existing = [d.get("secretKey") for d in doc["spec"]["data"]]
if SECRET_KEY in existing:
    print("   ExternalSecret already carries %s -- leaving it" % SECRET_KEY)
else:
    lines = open(ES).readlines()
    idx = next(i for i, l in enumerate(lines) if l.rstrip("\n") == "  data:")
    entry = [
        "    # INFRA-1639. The Entra OIDC client secret, merged into argocd-secret so\n",
        "    # argocd-cm can reference it as $%s.\n" % SECRET_KEY,
        "    - secretKey: %s\n" % SECRET_KEY,
        "      remoteRef:\n",
        "        key: %s\n" % sm_key,
        "        property: client_secret\n",
    ]
    lines[idx+1:idx+1] = entry
    open(ES, "w").writelines(lines)
    print("   ExternalSecret: + %s from %s" % (SECRET_KEY, sm_key))

after = yaml.safe_load(open(ES))
got = [d for d in after["spec"]["data"] if d.get("secretKey") == SECRET_KEY]
assert len(got) == 1, "expected exactly one %s entry, got %d" % (SECRET_KEY, len(got))
assert got[0]["remoteRef"]["key"] == sm_key, got[0]["remoteRef"]["key"]
assert got[0]["remoteRef"]["property"] == "client_secret", got[0]["remoteRef"]
assert after["spec"]["target"]["creationPolicy"] == "Merge"
# nothing else lost
assert set(existing).issubset({d.get("secretKey") for d in after["spec"]["data"]}), \
    "an existing data entry disappeared"

# ------------------------------------------------------------------ oidc.config
lines = open(HR).readlines()
out, added, dropped = [], False, False
for ln in lines:
    if ln.strip() == "enablePKCEAuthentication: true":
        dropped = True
        continue                       # a confidential client does not use PKCE here
    out.append(ln)
    if ln.rstrip("\n") == "          clientID: 42dc0c33-4c56-47a5-b207-d119272997aa":
        out.append("          clientSecret: $%s\n" % SECRET_KEY)
        added = True
assert added, "clientID line not found -- has the oidc.config PR landed on %s?" % br
open(HR, "w").writelines(out)
print("   oidc.config: + clientSecret reference" + (", - enablePKCEAuthentication" if dropped else ""))

v = yaml.safe_load(open(HR))["spec"]["values"]
o = yaml.safe_load(v["configs"]["cm"]["oidc.config"])
assert o["clientSecret"] == "$%s" % SECRET_KEY, o.get("clientSecret")
assert "enablePKCEAuthentication" not in o, "PKCE flag survived"
assert o["issuer"].endswith("/v2.0"), o["issuer"]
assert v["dex"]["enabled"] is False, "dex re-enabled"
PY

echo
git --no-pager diff -- infrastructure/argocd
[ "$PUSH" = "--push" ] || { echo; echo "   DRY RUN -- re-run with --push"; exit 0; }

BODY=$(mktemp); trap 'rm -f "$BODY"' EXIT
cat > "$BODY" <<'MD'
Completes the Entra OIDC switch.

Entra rejected the first attempt at the callback with `AADSTS9002327`: a code issued
to a Single-Page Application client may only be redeemed cross-origin. `argocd-server`
redeems the code from the backend, so this has to be a confidential client with a
secret — which is how the cloud EKS fleet's own Argo registration is set up.

The secret merges into `argocd-secret` through the ExternalSecret that is already
there, so `server.secretkey` from the install this cluster adopted is untouched.
No new file and no kustomization change.

The Secrets Manager path is derived from the branch, not copied, so this does not
carry a dev path onto another cluster.

Verify by signing in: the callback should complete rather than returning an
`AADSTS` code, and the session should land on `role:admin`.
MD
git add infrastructure/argocd
git commit -qm "INFRA-1639: Entra OIDC client secret via the existing argocd-secret ExternalSecret

Argo redeems the authorization code server-side, so the registration is a
confidential client and oidc.config needs a clientSecret. Merged into argocd-secret
rather than owned, leaving server.secretkey intact."
git push -q -u origin "$TOPIC"
gh pr create --base "$BR" --head "$TOPIC" \
  --title "INFRA-1639: Argo CD Entra OIDC client secret on $BR" --body-file "$BODY"

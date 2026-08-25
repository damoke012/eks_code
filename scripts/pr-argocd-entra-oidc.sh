#!/usr/bin/env bash
# INFRA-1639 -- switch Argo CD from Dex/SAML to Entra OIDC, direct, on one branch.
#
# Four edits to infrastructure/argocd/helmrelease.yaml:
#   1. configs.cm.oidc.config added -- Entra, PKCE, no client secret
#   2. configs.cm.dex.config removed  (if present)
#   3. dex.enabled -> false           (the deployment goes away)
#   4. policy.csv group name -> group OBJECT ID, with a comment saying why
#
# Built FROM the branch, never from wip/. Dry-run prints the diff; --push opens a PR.
#
#   scripts/pr-argocd-entra-oidc.sh op-dev
#   scripts/pr-argocd-entra-oidc.sh op-dev --push
set -euo pipefail

BR="${1:-}"; PUSH="${2:-}"
REPO="${REPO:-$HOME/pr-work/iaac-talos-flux-platform}"
TENANT="bbb5a66d-5c9f-482a-969a-a40304b6bc8d"
CLIENT_ID="42dc0c33-4c56-47a5-b207-d119272997aa"     # Argo CD On-Prem, created 2026-08-25
GROUP_ID="b9a1ff74-efa1-4b20-be8a-8706a5ab2636"      # usx-cloud-admin
GROUP_NAME="usx-cloud-admin"

case "$BR" in op-dev|op-qa|op-prod) : ;; *)
  echo "!! branch must be op-dev, op-qa or op-prod (got '${BR:-}')" >&2; exit 2 ;; esac
[ -d "$REPO/.git" ] || { echo "!! not a git repo: $REPO" >&2; exit 2; }

cd "$REPO"
git fetch -q origin
TOPIC="infra-1639-argocd-entra-oidc-$BR"
# Clean before checkout: an aborted earlier run leaves edits behind, and the next
# run would then assert against its own output rather than against the branch.
git checkout -q HEAD -- infrastructure/argocd 2>/dev/null || true
git clean -qfd infrastructure/argocd 2>/dev/null || true
git checkout -q -B "$TOPIC" "origin/$BR"
git checkout -q "origin/$BR" -- infrastructure/argocd
git clean -qfd infrastructure/argocd

HR="infrastructure/argocd/helmrelease.yaml"
[ -f "$HR" ] || { echo "!! $HR missing on $BR" >&2; exit 1; }

python3 - "$HR" "$BR" "$TENANT" "$CLIENT_ID" "$GROUP_ID" "$GROUP_NAME" <<'PY'
import sys, yaml
hr, br, tenant, client_id, group_id, group_name = sys.argv[1:7]
host = "argocd.%s.usxpress.io" % br

before = yaml.safe_load(open(hr))
cm_before = before["spec"]["values"]["configs"]["cm"]
assert cm_before.get("url") == "https://%s" % host, \
    "configs.cm.url is %r, expected https://%s -- wire the URL first" % (cm_before.get("url"), host)

lines = open(hr).readlines()

def block_end(i, indent):
    """Index one past the last continuation line of a block scalar starting at i."""
    j = i + 1
    while j < len(lines):
        ln = lines[j]
        if ln.strip() and (len(ln) - len(ln.lstrip())) <= indent:
            break
        j += 1
    return j

# ---- 2. drop dex.config, if this branch has one (only op-dev got the SAML connector)
out, removed = [], False
i = 0
while i < len(lines):
    ln = lines[i]
    if ln.rstrip("\n") == "        dex.config: |":
        i = block_end(i, 8); removed = True; continue
    out.append(ln); i += 1
lines = out

# ---- 3. dex.enabled -> false, scoped to the `    dex:` block so nothing else flips
out, in_dex, flipped, already = [], False, False, False
for ln in lines:
    if ln.rstrip("\n") == "    dex:":
        in_dex = True
    elif in_dex and ln.strip() and not ln.startswith("      "):
        in_dex = False
    if in_dex and ln.strip() == "enabled: true":
        ln = ln.replace("true", "false"); flipped = True
    elif in_dex and ln.strip() == "enabled: false":
        already = True
    out.append(ln)
assert flipped or already, "no `enabled:` found inside the dex block"
lines = out

# ---- 1. oidc.config as the first key under configs.cm
oidc = [
    "        oidc.config: |\n",
    "          name: Entra\n",
    "          issuer: https://login.microsoftonline.com/%s/v2.0\n" % tenant,
    "          clientID: %s\n" % client_id,
    "          enablePKCEAuthentication: true\n",
    '          requestedScopes: ["openid", "profile", "email", "groups"]\n',
]
out, done = [], False
for ln in lines:
    out.append(ln)
    if not done and ln.rstrip("\n") == "      cm:":
        out.extend(oidc); done = True
assert done, "did not find `      cm:`"
lines = out

# ---- 4. policy.csv: the group NAME cannot appear in an Entra token for a cloud-only
#        group, so the subject becomes the object ID. Comment it, or the next reader
#        finds a bare GUID with no way to resolve it.
old_rule = "          g, %s, role:admin\n" % group_name
new_rule = (
    "          # %s. Entra emits the group OBJECT ID, not the name: the group is\n"
    "          # cloud-only (onPremisesSyncEnabled null), and Entra can only emit a\n"
    "          # display name for AD-synced groups. Verified 2026-08-25.\n"
    "          g, %s, role:admin\n" % (group_name, group_id)
)
assert old_rule in lines, "policy.csv does not carry %r -- has the RBAC PR landed on %s?" % (old_rule.strip(), br)
lines[lines.index(old_rule)] = new_rule
open(hr, "w").writelines(lines)

# ---- parse it back and assert on the RESULT, not on the edits
after = yaml.safe_load(open(hr))
v = after["spec"]["values"]
cm = v["configs"]["cm"]
assert cm.get("url") == "https://%s" % host, "url did not survive"
assert "dex.config" not in cm, "dex.config still present"
o = yaml.safe_load(cm["oidc.config"])
assert o["clientID"] == client_id, o["clientID"]
assert o["issuer"] == "https://login.microsoftonline.com/%s/v2.0" % tenant, o["issuer"]
assert o["enablePKCEAuthentication"] is True, "PKCE off -- a client secret would be required"
assert "clientSecret" not in o, "a clientSecret appeared; PKCE needs a public client"
assert set(o["requestedScopes"]) == {"openid", "profile", "email", "groups"}, o["requestedScopes"]
assert v["dex"]["enabled"] is False, "dex still enabled"
csv = v["configs"]["rbac"]["policy.csv"]
assert ("g, %s, role:admin" % group_id) in csv, "policy.csv missing the object-ID rule"
assert ("g, %s, role:admin" % group_name) not in csv, "the old name-based rule is still active"
assert v["configs"]["rbac"].get("scopes") == "[groups]", v["configs"]["rbac"].get("scopes")

print("   dex.config removed" if removed else "   (no dex.config on this branch)")
print("   dex.enabled false" if flipped else "   (dex already disabled)")
print("   oidc.config added, policy.csv now keyed on the object ID")
PY

echo
git --no-pager diff --stat -- "$HR"
echo
git --no-pager diff -- "$HR"

if [ "$PUSH" != "--push" ]; then
  echo
  echo "   DRY RUN -- read the diff above, then re-run with --push"
  exit 0
fi

BODY=$(mktemp); trap 'rm -f "$BODY"' EXIT
cat > "$BODY" <<'MD'
Switches Argo CD on this cluster from Dex to Entra ID directly.

Argo CD speaks OIDC natively, so Dex was a hop with nothing in it. The cloud EKS
fleet already runs Argo this way; on-prem was the outlier.

Registered as a **public client with SPA redirect URIs**, so the flow is PKCE and
there is **no client secret** — no ExternalSecret, no Secrets Manager write, and
nothing to rotate. `argocd-secret` is not touched, so op-dev's `server.secretkey`
from the raw install it adopted survives.

The RBAC subject is the group's object ID rather than its name. Entra can only emit
a display name for AD-synced groups, and `usx-cloud-admin` is cloud-only. The GUID
carries a comment saying so.

One Entra app registration, `Argo CD On-Prem`, covers all three clusters; the
redirect URI is what distinguishes them, and access stays per-cluster because
`policy.csv` is per-branch.

Verify after sync: the login button reads Entra, `argocd-dex-server` is gone, and a
signed-in user lands on `role:admin`.
MD

git add "$HR"
git commit -qm "INFRA-1639: Argo CD SSO via Entra OIDC, dropping Dex

Public client with PKCE, so no client secret is stored or rotated. RBAC keyed on
the usx-cloud-admin object ID, since Entra cannot emit a display name for a
cloud-only group."
git push -q -u origin "$TOPIC"
gh pr create --base "$BR" --head "$TOPIC" \
  --title "INFRA-1639: Argo CD SSO via Entra OIDC on $BR (drops Dex)" \
  --body-file "$BODY"

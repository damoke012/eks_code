#!/usr/bin/env bash
# INFRA-1639 -- wire Argo CD Entra OIDC on op-qa or op-prod.
#
# These branches are NOT dev with a different hostname. Verified 2026-08-25:
#   op-qa   has configs.cm.url and the rbac block; NO ExternalSecret file at all.
#   op-prod has NEITHER url NOR an rbac block, and no ExternalSecret file.
# Both already have dex.enabled: false, so there is no Dex to remove.
#
# Because neither branch has dev's admin-externalsecret.yaml, the chart owns
# argocd-secret on these clusters. Merging into a Helm-owned secret risks the next
# chart upgrade dropping the key silently, so the client secret goes into its OWN
# secret labelled app.kubernetes.io/part-of: argocd, which Argo resolves via
# $argocd-entra-oidc:client_secret and Helm never touches.
#
# Adds only what a branch is missing, and asserts on the re-parsed result.
#
#   scripts/pr-argocd-entra-qa-prod.sh op-qa
#   scripts/pr-argocd-entra-qa-prod.sh op-qa --push
set -euo pipefail
BR="${1:-}"; PUSH="${2:-}"
REPO="${REPO:-$HOME/pr-work/iaac-talos-flux-platform}"
case "$BR" in op-qa|op-prod) : ;; *)
  echo "!! this script is for op-qa or op-prod (op-dev is already wired)" >&2; exit 2 ;; esac
[ -d "$REPO/.git" ] || { echo "!! not a git repo: $REPO" >&2; exit 2; }

cd "$REPO"
git fetch -q origin
TOPIC="infra-1639-argocd-entra-$BR"
git checkout -q HEAD -- infrastructure/argocd 2>/dev/null || true
git clean -qfd infrastructure/argocd 2>/dev/null || true
git checkout -q -B "$TOPIC" "origin/$BR"
git checkout -q "origin/$BR" -- infrastructure/argocd
git clean -qfd infrastructure/argocd

python3 - "$BR" <<'PY'
import sys, yaml, os
br = sys.argv[1]
cluster = "op-usxpress-%s" % br[len("op-"):]
host    = "argocd.%s.usxpress.io" % br
sm_key  = "%s/platform/argocd/azure-ad" % cluster
TENANT  = "bbb5a66d-5c9f-482a-969a-a40304b6bc8d"
CLIENT  = "42dc0c33-4c56-47a5-b207-d119272997aa"
GROUP   = "b9a1ff74-efa1-4b20-be8a-8706a5ab2636"
SECNAME = "argocd-entra-oidc"

HR = "infrastructure/argocd/helmrelease.yaml"

# Where this branch keeps its Argo ExternalSecrets, and which apiVersion it serves.
# Both are read from the branch. op-dev keeps them in infrastructure/argocd/ and
# op-qa in infrastructure/argocd-config/; op-qa serves external-secrets.io/v1 while
# the value carried over from memory was v1beta1. Assuming either froze op-qa
# delivery on 2026-08-25.
import glob, collections
es_files = []
for f in glob.glob("infrastructure/**/*.yaml", recursive=True):
    head = open(f, encoding="utf-8", errors="replace").read(4000)
    if "kind: ExternalSecret" in head:
        es_files.append(f)
assert es_files, "no ExternalSecret anywhere under infrastructure/ on %s -- inspect by hand" % br

vers = collections.Counter()
for f in es_files:
    for line in open(f, encoding="utf-8", errors="replace"):
        if line.startswith("apiVersion:"):
            vers[line.split(":", 1)[1].strip()] += 1
            break
ES_API = vers.most_common(1)[0][0]
assert ES_API.startswith("external-secrets.io/"), ES_API

argocd_es = [f for f in es_files if f.startswith("infrastructure/argocd")]
ES_DIR = os.path.dirname(sorted(argocd_es)[0]) if argocd_es else "infrastructure/argocd"
ES = os.path.join(ES_DIR, "entra-oidc-externalsecret.yaml")
KU = os.path.join(ES_DIR, "kustomization.yaml")
assert os.path.exists(KU), "no kustomization.yaml in %s" % ES_DIR
print("   ExternalSecrets on %s live in %s and use %s (%d sampled)"
      % (br, ES_DIR, ES_API, sum(vers.values())))

did = []

# ---------------------------------------------------------------- ExternalSecret
# Its own secret, not a merge into the chart-owned argocd-secret. The part-of
# label is what makes Argo resolve $argocd-entra-oidc:client_secret against it.
open(ES, "w").write("""apiVersion: %s
kind: ExternalSecret
metadata:
  name: %s
  namespace: argocd
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: default
  target:
    name: %s
    creationPolicy: Owner
    template:
      type: Opaque
      metadata:
        labels:
          # Argo only resolves a $name:key reference against secrets carrying this
          # label. Without it the reference silently stays a literal string.
          app.kubernetes.io/part-of: argocd
      data:
        client_secret: "{{ .client_secret }}"
  data:
    - secretKey: client_secret
      remoteRef:
        key: %s
        property: client_secret
""" % (ES_API, SECNAME, SECNAME, sm_key))
did.append("added %s" % ES)

ku = open(KU).read()
if os.path.basename(ES) not in ku:
    lines = ku.splitlines(True)
    i = max(n for n, l in enumerate(lines) if l.startswith("  - "))
    lines.insert(i + 1, "  - %s\n" % os.path.basename(ES))
    open(KU, "w").writelines(lines)
    did.append("listed it in %s" % KU)

# ------------------------------------------------------------------ helmrelease
lines = open(HR).readlines()
doc = yaml.safe_load("".join(lines))
cm  = doc["spec"]["values"]["configs"].get("cm") or {}
rbac= doc["spec"]["values"]["configs"].get("rbac")

assert doc["spec"]["values"]["dex"]["enabled"] is False, "dex is enabled on %s; not expected" % br
assert "oidc.config" not in cm, "oidc.config already present on %s" % br

oidc = [
    "        oidc.config: |\n",
    "          name: Entra\n",
    "          issuer: https://login.microsoftonline.com/%s/v2.0\n" % TENANT,
    "          clientID: %s\n" % CLIENT,
    "          clientSecret: $%s:client_secret\n" % SECNAME,
    '          requestedScopes: ["openid", "profile", "email"]\n',
]
if "url" not in cm:
    oidc.append("        # INFRA-1639. Without this Argo builds its redirect_uri from the\n")
    oidc.append("        # chart default https://argocd.example.com, which no IdP can reach.\n")
    oidc.append("        url: https://%s\n" % host)
    did.append("added configs.cm.url")

out, done = [], False
for ln in lines:
    out.append(ln)
    if not done and ln.rstrip("\n") == "      cm:":
        out.extend(oidc); done = True
assert done, "did not find `      cm:` on %s" % br
did.append("added oidc.config")
lines = out

# rbac: rekey dev/QA's existing rule, or add the whole block where prod has none
rule_name = "          g, usx-cloud-admin, role:admin\n"
new_rule  = ("          # usx-cloud-admin. Entra emits the group OBJECT ID, not the name: the\n"
             "          # group is cloud-only (onPremisesSyncEnabled null) and Entra can emit a\n"
             "          # display name only for AD-synced groups. Verified 2026-08-25.\n"
             "          g, %s, role:admin\n" % GROUP)
if rule_name in lines:
    lines[lines.index(rule_name)] = new_rule
    did.append("rekeyed policy.csv to the object ID")
elif rbac is None:
    block = [
        "      rbac:\n",
        '        # INFRA-1639. Unset, the chart defaults leave an SSO user with NO access.\n',
        '        policy.default: ""\n',
        "        policy.csv: |\n",
    ] + new_rule.splitlines(True) + [
        '        scopes: "[groups]"\n',
    ]
    out, done = [], False
    for ln in lines:
        if not done and ln.rstrip("\n") == "    configs:":
            out.append(ln); out.extend(block); done = True; continue
        out.append(ln)
    assert done, "did not find `    configs:` on %s" % br
    lines = out
    did.append("added the whole rbac block (none existed)")
else:
    raise AssertionError("rbac exists but carries no usx-cloud-admin rule; inspect it by hand")

open(HR, "w").writelines(lines)

# ------------------------------------------- assert on the result, not the edits
v = yaml.safe_load(open(HR))["spec"]["values"]
cm = v["configs"]["cm"]; rb = v["configs"]["rbac"]
o = yaml.safe_load(cm["oidc.config"])
assert cm["url"] == "https://%s" % host, cm.get("url")
assert o["clientID"] == CLIENT and o["issuer"].endswith("/v2.0")
assert o["clientSecret"] == "$%s:client_secret" % SECNAME, o.get("clientSecret")
assert "enablePKCEAuthentication" not in o
assert "requestedIDTokenClaims" not in o, "the claims request was removed on dev; do not reintroduce it"
assert set(o["requestedScopes"]) == {"openid", "profile", "email"}
assert v["dex"]["enabled"] is False
assert ("g, %s, role:admin" % GROUP) in rb["policy.csv"]
assert "usx-cloud-admin, role:admin" not in rb["policy.csv"]
assert rb.get("policy.default") == "" and rb.get("scopes") == "[groups]"

es = yaml.safe_load(open(ES))
assert es["spec"]["data"][0]["remoteRef"]["key"] == sm_key, "wrong cluster's Secrets Manager path"
assert es["spec"]["target"]["template"]["metadata"]["labels"]["app.kubernetes.io/part-of"] == "argocd"
assert os.path.basename(ES) in open(KU).read()
assert es["apiVersion"] == ES_API, es["apiVersion"]
for line in did: print("   " + line)
PY

echo
git --no-pager diff -- infrastructure/argocd
git --no-pager status --short -- infrastructure/argocd
# A new manifest written from another cluster's layout froze op-qa delivery on
# 2026-08-25 (external-secrets.io/v1beta1 against a cluster serving v1). Gate on it.
LINT="$(dirname "$0")/lint-manifest-apiversions.py"
if [ -f "$LINT" ]; then
  echo
  python3 "$LINT" "$REPO" "$BR" || {
    echo "!! apiVersion disagreement above -- not pushing." >&2
    echo "   Confirm what the cluster serves before overriding." >&2
    exit 1; }
fi

[ "$PUSH" = "--push" ] || { echo; echo "   DRY RUN -- re-run with --push"; exit 0; }

BODY=$(mktemp); trap 'rm -f "$BODY"' EXIT
cat > "$BODY" <<MD
Brings this cluster onto the Entra OIDC setup proven on op-dev today.

**Authentication only.** Entra currently issues tokens for this application with no
\`groups\` claim, so an SSO user authenticates and then matches nothing in
\`policy.csv\`. Local admin login is unaffected, so nobody is locked out. Tracking
separately; this PR is the cluster-side wiring so the fix lands everywhere at once.

Not a copy of the dev change. This branch had no ExternalSecret file, which means
the chart owns \`argocd-secret\` here — merging into it risks the next chart upgrade
dropping the key. The client secret therefore gets its own secret carrying
\`app.kubernetes.io/part-of: argocd\`, which Argo resolves as
\`\$argocd-entra-oidc:client_secret\` and Helm never touches.

The Secrets Manager path is derived from the branch, so this cannot point at
another cluster's secret. \`dex\` was already disabled here.

Requires the secret to exist first:
\`scripts/entra-argocd-to-web-client.sh --secret $BR <profile>\`
MD
git add infrastructure/argocd
git commit -qm "INFRA-1639: Argo CD Entra OIDC on $BR

Adds only what this branch lacked. The client secret lands in its own labelled
secret rather than merging into the chart-owned argocd-secret, and the RBAC subject
is the usx-cloud-admin object ID because Entra cannot emit a display name for a
cloud-only group."
git push -q -u origin "$TOPIC"
gh pr create --base "$BR" --head "$TOPIC" \
  --title "INFRA-1639: Argo CD Entra OIDC on $BR" --body-file "$BODY"

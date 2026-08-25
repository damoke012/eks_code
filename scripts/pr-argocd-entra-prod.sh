#!/usr/bin/env bash
# INFRA-1639 -- bring op-prod up to dev/QA on Argo CD Entra OIDC, in one PR.
#
# op-prod needs FIVE things, not the three op-qa needed. Verified 2026-08-25:
#   * no VirtualService for argocd  -> argocd.op-prod.usxpress.io does not resolve,
#     so the OIDC callback has nowhere to land. This is the piece nobody had scoped.
#   * no configs.cm.url             -> Argo would build redirect_uri from the chart
#     default https://argocd.example.com
#   * no configs.rbac block at all
#   * no oidc.config
#   * no ExternalSecret for the client secret
#
# Everything is DERIVED FROM THE op-prod BRANCH -- the ExternalSecret directory, its
# apiVersion, its ClusterSecretStore, and the route's gateway/targets/TLS. Carrying
# any of these over from another cluster is what froze op-qa delivery today.
#
# The op-prod cluster has NO kubeconfig on this workstation, so nothing here can be
# confirmed against the running cluster. That is called out in the PR body rather
# than papered over.
#
#   scripts/pr-argocd-entra-prod.sh
#   scripts/pr-argocd-entra-prod.sh --push
set -euo pipefail
PUSH="${1:-}"
BR=op-prod
REPO="${REPO:-$HOME/pr-work/iaac-talos-flux-platform}"
[ -d "$REPO/.git" ] || { echo "!! not a git repo: $REPO" >&2; exit 2; }

cd "$REPO"
git fetch -q origin
TOPIC="infra-1639-argocd-entra-$BR"
git checkout -q HEAD -- infrastructure 2>/dev/null || true
git clean -qfd infrastructure 2>/dev/null || true
git checkout -q -B "$TOPIC" "origin/$BR"
git checkout -q "origin/$BR" -- infrastructure
git clean -qfd infrastructure

python3 - <<'PY'
import os, glob, collections, yaml

BR       = "op-prod"
CLUSTER  = "op-usxpress-prod"
HOST     = "argocd.op-prod.usxpress.io"
SUFFIX   = "op-prod.usxpress.io"
SM_KEY   = "%s/platform/argocd/azure-ad" % CLUSTER
TENANT   = "bbb5a66d-5c9f-482a-969a-a40304b6bc8d"
CLIENT   = "42dc0c33-4c56-47a5-b207-d119272997aa"
GROUP    = "b9a1ff74-efa1-4b20-be8a-8706a5ab2636"
SECNAME  = "argocd-entra-oidc"
did = []

def load_all(p):
    """Skip what is not plain YAML instead of dying on it. This tree contains Helm
    chart templates (infrastructure/octopus-worker/chart/templates/) whose {{ }} a
    strict parser rejects -- and a scanner that crashes on the tree it is scanning
    is useless. Anything unparseable simply is not a candidate."""
    txt = open(p, encoding="utf-8", errors="replace").read()
    if "{{" in txt:
        return []
    try:
        return [d for d in yaml.safe_load_all(txt) if isinstance(d, dict)]
    except yaml.YAMLError:
        return []

# ---------------------------------------------- 1. where ExternalSecrets live here
es_files = []
for f in glob.glob("infrastructure/**/*.yaml", recursive=True):
    txt = open(f, encoding="utf-8", errors="replace").read()
    if "kind: ExternalSecret" in txt and "{{" not in txt:
        es_files.append(f)
assert es_files, "no ExternalSecret under infrastructure/ on %s" % BR
vers, stores = collections.Counter(), collections.Counter()
for f in es_files:
    for d in load_all(f):
        if d.get("kind") != "ExternalSecret": continue
        vers[d["apiVersion"]] += 1
        ref = (d.get("spec") or {}).get("secretStoreRef") or {}
        if ref.get("name"): stores[(ref.get("kind", "ClusterSecretStore"), ref["name"])] += 1
ES_API = vers.most_common(1)[0][0]
(ST_KIND, ST_NAME) = stores.most_common(1)[0][0]
argocd_es = sorted(f for f in es_files if f.startswith("infrastructure/argocd"))
assert argocd_es, "no ExternalSecret under infrastructure/argocd* on %s" % BR
ES_DIR = os.path.dirname(argocd_es[0])
print("   ExternalSecrets: %s, %s, store %s/%s" % (ES_DIR, ES_API, ST_KIND, ST_NAME))

# ------------------------------- 2. a route on THIS cluster to copy the wiring from
# Never generalise DNS targets: op-dev uses all 7 workers, op-qa 3 of 13. And never
# trust a route whose hostname belongs to another cluster -- op-qa was found live
# serving grafana.op-dev.usxpress.io on 2026-08-24, and this branch is a copy of it.
ref_vs = None
for f in sorted(glob.glob("infrastructure/**/*.yaml", recursive=True)):
    if "/argocd" in f: continue
    for d in load_all(f):
        if d.get("kind") != "VirtualService": continue
        hosts = (d.get("spec") or {}).get("hosts") or []
        if any(str(h).endswith(SUFFIX) for h in hosts):
            ref_vs = (f, d); break
    if ref_vs: break
assert ref_vs, ("no VirtualService on %s whose host ends in %s -- every route here "
                "belongs to another cluster, so there is nothing safe to copy." % (BR, SUFFIX))
rf, rd = ref_vs
rhosts = rd["spec"]["hosts"]
assert all(str(h).endswith(SUFFIX) for h in rhosts), \
    "%s serves %r -- a foreign hostname; refusing to copy its wiring" % (rf, rhosts)
GATEWAYS = rd["spec"]["gateways"]
ANN = (rd.get("metadata") or {}).get("annotations") or {}
TARGETS = ANN.get("external-dns.alpha.kubernetes.io/target")
assert TARGETS, ("%s has no external-dns target annotation. istio-ingressgateway is "
                 "ClusterIP+hostNetwork with no LB address, so the annotation is "
                 "REQUIRED or no record is published." % rf)
print("   route model: %s" % rf)
print("     hosts    %s" % rhosts)
print("     gateways %s" % GATEWAYS)
print("     targets  %s" % TARGETS)

vs = {
    "apiVersion": rd["apiVersion"],
    "kind": "VirtualService",
    "metadata": {
        "name": "argocd-server",
        "namespace": "argocd",
        "annotations": {"external-dns.alpha.kubernetes.io/target": TARGETS},
    },
    "spec": {
        "hosts": [HOST],
        "gateways": GATEWAYS,
        "http": [{"route": [{"destination": {"host": "argocd-server.argocd.svc.cluster.local",
                                             "port": {"number": 80}}}]}],
    },
}
VS_PATH = os.path.join(ES_DIR, "virtualservice-argocd.yaml")
with open(VS_PATH, "w") as fh:
    fh.write("# INFRA-1639. argocd.op-prod.usxpress.io did not resolve before this:\n"
             "# op-prod had no Argo route at all, so the OIDC callback had nowhere to\n"
             "# land. Gateway and external-dns targets are copied from %s, a route\n"
             "# already serving THIS cluster -- they are not the same across clusters.\n" % rf)
    yaml.safe_dump(vs, fh, sort_keys=False)
did.append("added %s" % VS_PATH)

# --------------------------------------------------------------- 3. ExternalSecret
ES_PATH = os.path.join(ES_DIR, "entra-oidc-externalsecret.yaml")
open(ES_PATH, "w").write("""apiVersion: %s
kind: ExternalSecret
metadata:
  name: %s
  namespace: argocd
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: %s
    name: %s
  target:
    name: %s
    creationPolicy: Owner
    template:
      type: Opaque
      metadata:
        labels:
          # Argo resolves a $name:key reference only against secrets carrying this
          # label. Without it the reference stays a literal string and SSO fails
          # with no error in the ConfigMap.
          app.kubernetes.io/part-of: argocd
      data:
        client_secret: "{{ .client_secret }}"
  data:
    - secretKey: client_secret
      remoteRef:
        key: %s
        property: client_secret
""" % (ES_API, SECNAME, ST_KIND, ST_NAME, SECNAME, SM_KEY))
did.append("added %s" % ES_PATH)

KU = os.path.join(ES_DIR, "kustomization.yaml")
ku = open(KU).readlines()
for base in (os.path.basename(VS_PATH), os.path.basename(ES_PATH)):
    if not any(l.strip() == "- %s" % base for l in ku):
        i = max(n for n, l in enumerate(ku) if l.startswith("  - "))
        ku.insert(i + 1, "  - %s\n" % base)
open(KU, "w").writelines(ku)
did.append("listed both in %s" % KU)

# ------------------------------------------------------------------ 4. helmrelease
HR = "infrastructure/argocd/helmrelease.yaml"
lines = open(HR).readlines()
doc = yaml.safe_load("".join(lines))
v = doc["spec"]["values"]
assert v["dex"]["enabled"] is False, "dex enabled on %s" % BR
assert "oidc.config" not in (v["configs"].get("cm") or {}), "oidc.config already present"
assert v["configs"].get("rbac") is None, "rbac block already exists -- inspect by hand"

block = [
    "      rbac:\n",
    '        # INFRA-1639. Unset, the chart defaults leave an SSO user with NO access.\n',
    '        policy.default: ""\n',
    "        policy.csv: |\n",
    "          # usx-cloud-admin. Entra emits the group OBJECT ID, not the name: the\n",
    "          # group is cloud-only (onPremisesSyncEnabled null) and Entra can emit a\n",
    "          # display name only for AD-synced groups. Verified 2026-08-25.\n",
    "          g, %s, role:admin\n" % GROUP,
    "        # Argo sees groups only if the provider emits a groups claim.\n",
    '        scopes: "[groups]"\n',
]
oidc = [
    "        oidc.config: |\n",
    "          name: Entra\n",
    "          issuer: https://login.microsoftonline.com/%s/v2.0\n" % TENANT,
    "          clientID: %s\n" % CLIENT,
    "          clientSecret: $%s:client_secret\n" % SECNAME,
    '          requestedScopes: ["openid", "profile", "email"]\n',
    "        # INFRA-1639 -- the base URL Argo builds every link, and its OIDC\n",
    "        # redirect_uri, from. Left unset it is https://argocd.example.com.\n",
    "        url: https://%s\n" % HOST,
]
out, did_cfg, did_cm = [], False, False
for ln in lines:
    if not did_cfg and ln.rstrip("\n") == "    configs:":
        out.append(ln); out.extend(block); did_cfg = True; continue
    out.append(ln)
    if not did_cm and ln.rstrip("\n") == "      cm:":
        out.extend(oidc); did_cm = True
assert did_cfg, "did not find `    configs:`"
assert did_cm, "did not find `      cm:`"
open(HR, "w").writelines(out)
did.append("helmrelease: rbac block, oidc.config and url")

# ------------------------------------------------- assert on the re-parsed result
v = yaml.safe_load(open(HR))["spec"]["values"]
cm, rb = v["configs"]["cm"], v["configs"]["rbac"]
o = yaml.safe_load(cm["oidc.config"])
assert cm["url"] == "https://%s" % HOST
assert o["clientID"] == CLIENT and o["clientSecret"] == "$%s:client_secret" % SECNAME
assert "enablePKCEAuthentication" not in o and "requestedIDTokenClaims" not in o
assert set(o["requestedScopes"]) == {"openid", "profile", "email"}
assert v["dex"]["enabled"] is False
assert ("g, %s, role:admin" % GROUP) in rb["policy.csv"] and rb["policy.default"] == ""
assert rb["scopes"] == "[groups]"
e = yaml.safe_load(open(ES_PATH))
assert e["apiVersion"] == ES_API and e["spec"]["secretStoreRef"]["name"] == ST_NAME
assert e["spec"]["data"][0]["remoteRef"]["key"] == SM_KEY
r = yaml.safe_load(open(VS_PATH).read().split("\n", 4)[-1])
assert r["spec"]["hosts"] == [HOST] and r["spec"]["gateways"] == GATEWAYS
assert r["metadata"]["annotations"]["external-dns.alpha.kubernetes.io/target"] == TARGETS
k = open(KU).read()
assert os.path.basename(VS_PATH) in k and os.path.basename(ES_PATH) in k
for line in did: print("   " + line)
PY

LINT="$(cd "$(dirname "$0")" && pwd)/lint-manifest-apiversions.py"
[ -f "$LINT" ] && { echo; python3 "$LINT" "$REPO" "$BR" || {
  echo "!! apiVersion disagreement -- not pushing." >&2; exit 1; }; }

echo
git --no-pager diff -- infrastructure
git --no-pager status --short -- infrastructure
[ "$PUSH" = "--push" ] || { echo; echo "   DRY RUN -- re-run with --push"; exit 0; }

BODY=$(mktemp); trap 'rm -f "$BODY"' EXIT
cat > "$BODY" <<'MD'
Brings op-prod to the Entra OIDC setup running on op-dev and op-qa.

op-prod needed more than the other two. It had **no Argo route at all** —
`argocd.op-prod.usxpress.io` did not resolve, so the OIDC callback had nowhere to
land — plus no `configs.cm.url`, no `rbac` block, no `oidc.config` and no
ExternalSecret.

Every value is derived from this branch, not carried across: the ExternalSecret's
directory, apiVersion and ClusterSecretStore, and the route's gateway, TLS wiring
and external-dns targets. Targets in particular are not portable — op-dev uses all
7 workers, op-qa 3 of 13 — so they are copied from a route already serving this
cluster, after checking that route's hostname belongs to it.

**Authentication only.** Entra currently issues tokens for this application with no
`groups` claim, so an SSO user will authenticate and match nothing in `policy.csv`.
`policy.default` is `""`, so they get no access rather than wrong access, and local
admin login is unaffected. Tracked separately.

**Not verified against the running cluster.** There is no op-prod kubeconfig on the
workstation this was built from, so the ClusterSecretStore named here comes from the
branch's own working ExternalSecret rather than from the cluster. Worth a look at
the ExternalSecret's status after this syncs — `SecretSynced` alone proves only that
the sync ran.

Requires the secret to exist first:
`ALLOW_PROD_WRITE=yes scripts/entra-argocd-to-web-client.sh --secret op-prod ops-controller`
MD
git add -A infrastructure
git commit -qm "INFRA-1639: Argo CD Entra OIDC on op-prod, with the route it never had

op-prod had no VirtualService for argocd, so the hostname did not resolve and the
OIDC callback had nowhere to land. Adds that alongside url, the rbac block,
oidc.config and the ExternalSecret. Route wiring and secret-store details are
derived from this branch, since none of them are the same across clusters."
git push -q -u origin "$TOPIC"
gh pr create --base "$BR" --head "$TOPIC" \
  --title "INFRA-1639: Argo CD Entra OIDC on op-prod (adds the missing route)" --body-file "$BODY"

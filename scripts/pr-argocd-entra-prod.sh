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
# Resolve before ANY cd. Three scripts today have looked up a sibling with a
# relative path after cd-ing into the platform repo, and each time the failure read
# as "the cluster is unreachable" rather than "the script cannot find itself".
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# Read the route wiring off the live cluster and hand it to the builder. The branch
# cannot supply it -- every route there belongs to op-dev.
LIB="$SCRIPT_DIR/lib-onprem-ctx.sh"
# shellcheck source=/dev/null
source "$LIB"; onprem_resolve_ctx "$BR" || {
  echo "!! need the op-prod cluster. Rebuild access first:" >&2
  echo "   scripts/onprem-prod-kubeconfig.sh ops-controller" >&2; exit 1; }
K() { kubectl --kubeconfig="$ONPREM_KC" --context="$ONPREM_CTX" "$@"; }

# the nodes actually running istio-ingressgateway, then their InternalIPs
NODES=$(K -n istio-ingress get pods -l app=istio-ingressgateway           -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort -u)
[ -n "$NODES" ] || { echo "!! no istio-ingressgateway pods on $BR" >&2; exit 1; }
IPS=""
for n in $NODES; do
  ip=$(K get node "$n" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
  [ -n "$ip" ] && IPS="${IPS:+$IPS,}$ip"
done
[ -n "$IPS" ] || { echo "!! could not read node InternalIPs on $BR" >&2; exit 1; }

GW=$(K get gateways.networking.istio.io -A        -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null      | grep -E '/shared-http$' | head -1)
[ -n "$GW" ] || { echo "!! no shared-http Gateway on $BR" >&2; exit 1; }

# The Gateway must already serve this cluster's hostnames, or the route cannot match.
# Parse JSON rather than nested jsonpath ranges: `{range .spec.servers[*]}{range
# .hosts[*]}{.}{end}{end}` returns only the separators, so the guard read an empty
# string and reported the Gateway as serving the wrong hosts.
GWHOSTS=$(K -n "${GW%%/*}" get gateways.networking.istio.io "${GW##*/}" -o json 2>/dev/null \
          | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
hosts = []
for srv in (d.get("spec") or {}).get("servers") or []:
    hosts += srv.get("hosts") or []
print(" ".join(hosts))')
[ -n "${GWHOSTS// /}" ] || { echo "!! read no hosts at all from $GW -- refusing to guess." >&2; exit 1; }
echo "   $GW serves: $GWHOSTS"
case "$GWHOSTS" in
  *op-prod.usxpress.io*) : ;;
  *) echo "!! $GW serves '$GWHOSTS' -- not op-prod hostnames." >&2
     echo "   An argocd.op-prod.usxpress.io route would never match it. Land this first:" >&2
     echo "     scripts/pr-istio-gateway-op-prod.sh --push" >&2
     exit 1 ;;
esac
# The route's destination is a Service on THIS cluster, so read it here rather than
# writing argocd-server:80 from memory -- the port names differ between a chart install
# and the adopted raw install op-dev started from.
ARGOCD_SVC=$(K -n argocd get svc argocd-server -o json 2>/dev/null) || ARGOCD_SVC=""
[ -n "$ARGOCD_SVC" ] || { echo "!! no argocd-server Service in the argocd namespace on $BR." >&2
  echo "   Argo CD itself must be running there before it can be routed to." >&2; exit 1; }
export ARGOCD_SVC

export ARGOCD_DNS_TARGETS="$IPS"
export ARGOCD_GATEWAYS="$GW"

python3 - <<'PY'
import os, glob, json, collections, yaml

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

# --------------------- 2. route wiring, read from the LIVE cluster, not the branch
# The op-prod branch has no route that belongs to op-prod: all 5 of its
# VirtualServices carry op-dev hostnames and dev's worker IPs. So the targets come
# from the cluster itself -- the node addresses where istio-ingressgateway is
# actually running. That is the value external-dns must publish, and it is not the
# same shape as the other clusters: op-dev 7 workers, op-qa 3 of 13, op-prod all 10.
import subprocess, json
TARGETS = os.environ.get("ARGOCD_DNS_TARGETS", "").strip()
GATEWAYS = [g for g in os.environ.get("ARGOCD_GATEWAYS", "").split(",") if g]
assert TARGETS, "ARGOCD_DNS_TARGETS not set -- the wrapper reads it from the cluster"
assert GATEWAYS, "ARGOCD_GATEWAYS not set"
print("   route wiring, from the live cluster:")
print("     gateways %s" % GATEWAYS)
print("     targets  %s" % TARGETS)

# The document's SHAPE comes from a VirtualService already on this branch -- its
# apiVersion and its external-dns annotation key. Those are conventions of this repo,
# not facts about op-prod, so the branch is the right source. Only the values that are
# per-cluster (host, gateway, targets, destination) are overridden, from the cluster.
template = None
for f in sorted(glob.glob("infrastructure/**/virtualservice*.yaml", recursive=True)):
    for d in load_all(f):
        if d.get("kind") == "VirtualService":
            template = (f, d); break
    if template: break
assert template, "no VirtualService on %s to take the file shape from" % BR
TPL_FILE, TPL = template
VS_API = TPL["apiVersion"]
ann_keys = [k for k in (TPL.get("metadata") or {}).get("annotations", {})
            if "external-dns" in k and k.endswith("/target")]
assert len(ann_keys) == 1, (
    "expected exactly one external-dns target annotation on %s, found %r"
    % (TPL_FILE, ann_keys))
DNS_ANN = ann_keys[0]
print("   file shape from %s (%s, %s)" % (TPL_FILE, VS_API, DNS_ANN))

svc = json.loads(os.environ["ARGOCD_SVC"])
SVC_NAME = svc["metadata"]["name"]
ports = {p.get("name"): p["port"] for p in svc["spec"]["ports"]}
# Prefer the plaintext port: argocd-server runs with server.insecure and TLS is
# terminated at the Gateway. Routing to 443 would double-terminate.
SVC_PORT = ports.get("http") or ports.get("server") or (
    80 if 80 in ports.values() else None)
assert SVC_PORT, ("no plaintext port on Service %s -- ports are %r. Refusing to guess "
                  "which one terminates TLS." % (SVC_NAME, ports))
print("   destination:     %s.argocd.svc.cluster.local:%s" % (SVC_NAME, SVC_PORT))

vs = {
    "apiVersion": VS_API,
    "kind": "VirtualService",
    "metadata": {
        "name": "argocd",
        "namespace": "argocd",
        "annotations": {DNS_ANN: TARGETS},
    },
    "spec": {
        "hosts": [HOST],
        "gateways": GATEWAYS,
        "http": [{
            "route": [{
                "destination": {
                    "host": "%s.argocd.svc.cluster.local" % SVC_NAME,
                    "port": {"number": SVC_PORT},
                },
            }],
        }],
    },
}

VS_PATH = os.path.join(ES_DIR, "virtualservice-argocd.yaml")
with open(VS_PATH, "w") as fh:
    fh.write("# INFRA-1639. argocd.op-prod.usxpress.io did not resolve before this:\n"
             "# op-prod had no Argo route at all, so the OIDC callback had nowhere to\n"
             "# land. Gateway and external-dns targets are read from the LIVE cluster --\n"
             "# the nodes where istio-ingressgateway actually runs. They are not the same\n"
             "# across clusters: op-dev 7 workers, op-qa 3 of 13, op-prod all 10.\n")
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

# The subject is an Entra APP ROLE value, not a group object ID.
#
# This tenant does not emit a `groups` claim for this application under any setting
# tried -- SecurityGroup, ApplicationGroup, `groups` in optionalClaims.idToken, no
# claims-mapping policy, 42 groups so no overage. A group-keyed subject here would
# authenticate fine and authorise nothing, which is what op-dev and op-qa shipped
# this morning and had to be rekeyed out of (PRs #138, #139).
#
# `roles` is issued from appRoleAssignments on the service principal instead, and
# PROVEN to arrive: op-dev token 2026-08-25 19:18:27Z carried roles -> platform-admin,
# with a negative control in the same log window (a user holding only default access
# got no claim). See wip/onprem-argocd/FINDINGS-2026-08-25-entra-oidc.md.
ADMIN_ROLE = "platform-admin"
block = [
    "      rbac:\n",
    '        # INFRA-1639. Unset, the chart defaults leave an SSO user with NO access.\n',
    '        policy.default: ""\n',
    "        policy.csv: |\n",
    "          # Subject is an Entra APP ROLE value. This tenant emits no groups claim\n",
    "          # for this application, so a group object ID here would match nothing --\n",
    "          # dev and QA shipped that and had to be rekeyed. `roles` comes from an\n",
    "          # appRoleAssignment on the SP and is proven to arrive.\n",
    "          # usx-cloud-admin (%s) holds it.\n" % GROUP,
    "          g, %s, role:admin\n" % ADMIN_ROLE,
    "        # Argo only searches the claims named here.\n",
    '        scopes: "[roles, groups]"\n',
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
assert ("g, %s, role:admin" % ADMIN_ROLE) in rb["policy.csv"], rb["policy.csv"]
assert rb["policy.default"] == "", rb["policy.default"]
assert rb["scopes"] == "[roles, groups]", rb["scopes"]
# No group object ID may survive as a subject: mixed kinds mean one of them can never
# match and the file does not show which.
import re as _re
_subj = [l.strip().split(",")[1].strip() for l in rb["policy.csv"].splitlines()
         if l.strip().startswith("g,") and len(l.strip().split(",")) >= 3]
assert not [x for x in _subj if _re.match(r"^[0-9a-fA-F-]{36}$", x)], \
    "a group object ID is still a subject: %r" % _subj
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

LINT="$SCRIPT_DIR/lint-manifest-apiversions.py"
[ -f "$LINT" ] && { echo; python3 "$LINT" "$REPO" "$BR" || {
  echo "!! apiVersion disagreement -- not pushing." >&2; exit 1; }; }

echo
# Stage first, and diff the INDEX. Two of the files this builds are new, and
# `git diff` without staging shows a modified kustomization.yaml listing resources
# whose contents are nowhere on screen. CLAUDE.md rule 7 says read the diff in full
# before pushing; a builder that hides its own new files makes that impossible.
git add -A -- infrastructure
git --no-pager diff --cached -- infrastructure
if [ "$PUSH" != "--push" ]; then
  git reset -q -- infrastructure
  echo; echo "   DRY RUN -- re-run with --push"; exit 0
fi

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

**Authorisation is keyed on `roles`, not `groups`.** This tenant does not emit a
`groups` claim for this application under any setting tried, so a group object ID as
a subject authenticates fine and authorises nothing — which is what dev and QA
shipped this morning and had to be rekeyed out of (#138, #139). `roles` is issued
from an appRoleAssignment on the service principal instead, and is proven to arrive:
an op-dev token at 19:18:27Z carried `roles -> platform-admin`, with a negative
control in the same window. `usx-cloud-admin` holds that role, so the same people
keep the same access.

`policy.default` stays `""` — no implicit access for merely authenticating — and the
local admin account is untouched.

**Read against the running cluster.** The route's gateway, DNS targets and the
destination Service were read from op-prod itself, not from this branch: every
VirtualService on this branch belongs to op-dev. `SecretSynced` on the ExternalSecret
proves only that the sync ran, so check the value once it lands.

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

#!/usr/bin/env bash
# INFRA-1639 / INFRA-1663 -- give op-prod its OWN ingress identity.
#
# Found 2026-08-25 against the live prod cluster:
#
#   istio-ingress/shared-http
#     port 80/HTTP   hosts=*.op-qa.usxpress.io
#     port 443/HTTPS hosts=*.op-qa.usxpress.io  cred=wildcard-op-qa-tls
#   TLS secrets in istio-ingress: (none)
#
# Production's shared Gateway serves QA's hostnames and references a TLS secret that
# does not exist on this cluster. shared-gateway.yaml and wildcard-cert.yaml on the
# op-prod branch are byte copies of op-qa's.
#
# Nothing is served through this Gateway today -- prod has ZERO live VirtualServices
# -- so correcting it cannot break a working route. It is a prerequisite for any
# prod route at all, Argo included.
#
#   scripts/pr-istio-gateway-op-prod.sh
#   scripts/pr-istio-gateway-op-prod.sh --push
set -euo pipefail
# Resolve before any cd -- this script cds into the platform repo.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUSH="${1:-}"
BR=op-prod
REPO="${REPO:-$HOME/pr-work/iaac-talos-flux-platform}"
[ -d "$REPO/.git" ] || { echo "!! not a git repo: $REPO" >&2; exit 2; }

# ---- verify against the live cluster before proposing anything
LIB="$SCRIPT_DIR/lib-onprem-ctx.sh"
# shellcheck source=/dev/null
source "$LIB"; onprem_resolve_ctx "$BR" || {
  echo "!! need the op-prod cluster to verify the issuer. Rebuild access first:" >&2
  echo "   scripts/onprem-prod-kubeconfig.sh ops-controller" >&2; exit 1; }
K() { kubectl --kubeconfig="$ONPREM_KC" --context="$ONPREM_CTX" "$@"; }

echo "== ClusterIssuer letsencrypt-prod on $BR"
ISS=$(K get clusterissuer letsencrypt-prod -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>&1) || true
[ "$ISS" = "True" ] || { echo "!! letsencrypt-prod is not Ready on $BR (got '${ISS}')." >&2
                         echo "   A wildcard Certificate cannot be issued; fix the issuer first." >&2; exit 1; }
echo "   Ready=True"
echo "== a wildcard needs a DNS-01 solver"
K get clusterissuer letsencrypt-prod -o jsonpath='{range .spec.acme.solvers[*]}{.dns01.route53.region}{" "}{end}' 2>/dev/null | sed 's/^/   route53 regions: /'
echo

cd "$REPO"
git fetch -q origin
TOPIC="infra-1663-istio-gateway-$BR"
git checkout -q HEAD -- infrastructure 2>/dev/null || true
git clean -qfd infrastructure 2>/dev/null || true
git checkout -q -B "$TOPIC" "origin/$BR"
git checkout -q "origin/$BR" -- infrastructure
git clean -qfd infrastructure

python3 - <<'PY'
import yaml
GW = "infrastructure/istio-ingress/shared-gateway.yaml"
CT = "infrastructure/istio-ingress/wildcard-cert.yaml"

for p in (GW, CT):
    txt = open(p).read()
    assert "op-qa" in txt, "%s carries no op-qa literal -- already fixed?" % p
    # Every op-qa occurrence in these two files IS the cluster identity: the
    # Certificate name, its secretName, the dnsNames, the Gateway hosts and its
    # credentialName. Nothing else in them refers to another cluster on purpose.
    open(p, "w").write(txt.replace("op-qa", "op-prod"))
    assert "op-qa" not in open(p).read(), p

g = yaml.safe_load(open(GW))
assert g["kind"] == "Gateway" and g["metadata"]["name"] == "shared-http", g["metadata"]
for s in g["spec"]["servers"]:
    for h in s["hosts"]:
        assert "op-qa" not in h, h
        assert h.endswith("op-prod.usxpress.io"), h
    tls = s.get("tls") or {}
    if tls.get("credentialName"):
        assert tls["credentialName"] == "wildcard-op-prod-tls", tls["credentialName"]

c = yaml.safe_load(open(CT))
assert c["kind"] == "Certificate"
assert c["metadata"]["name"] == "wildcard-op-prod", c["metadata"]["name"]
assert c["spec"]["secretName"] == "wildcard-op-prod-tls", c["spec"]["secretName"]
for d in c["spec"]["dnsNames"]:
    assert d.endswith("op-prod.usxpress.io"), d
# the secret the Gateway asks for must be the one the Certificate produces
creds = {s.get("tls", {}).get("credentialName") for s in g["spec"]["servers"]}
creds.discard(None)
assert creds == {c["spec"]["secretName"]}, (creds, c["spec"]["secretName"])
print("   Gateway hosts and Certificate now name op-prod, and the credentialName")
print("   matches the Certificate's secretName")
PY

echo
git --no-pager diff -- infrastructure/istio-ingress
[ "$PUSH" = "--push" ] || { echo; echo "   DRY RUN -- re-run with --push"; exit 0; }

BODY=$(mktemp); trap 'rm -f "$BODY"' EXIT
cat > "$BODY" <<'MD'
Production's shared ingress Gateway is serving QA's identity. Read from the live
cluster today:

```
istio-ingress/shared-http
  port 80/HTTP   hosts=*.op-qa.usxpress.io
  port 443/HTTPS hosts=*.op-qa.usxpress.io  cred=wildcard-op-qa-tls
TLS secrets in istio-ingress: (none)
```

`shared-gateway.yaml` and `wildcard-cert.yaml` on this branch are byte copies of
op-qa's, so prod has no wildcard certificate of its own and the secret the Gateway
references does not exist here.

Consequences: no `*.op-prod.usxpress.io` route can ever match this Gateway, and
HTTPS on it cannot terminate. That blocks every prod route, not just Argo CD's.

**This cannot break a working route** — prod currently has zero live
VirtualServices, so nothing is served through this Gateway at all.

`letsencrypt-prod` was verified Ready on this cluster before proposing the
Certificate.

After merge, watch the Certificate actually issue — `Ready=True` on the Certificate
and a `wildcard-op-prod-tls` secret appearing in `istio-ingress`. A wildcard needs
the DNS-01 solver to complete; the Certificate object existing is not the same as a
usable secret.
MD
git add infrastructure/istio-ingress
git commit -qm "INFRA-1663: give op-prod its own ingress identity

The shared Gateway served *.op-qa.usxpress.io and referenced wildcard-op-qa-tls,
which does not exist on this cluster; both files were byte copies of op-qa's. No
prod hostname could match, and HTTPS could not terminate."
git push -q -u origin "$TOPIC"
gh pr create --base "$BR" --head "$TOPIC" \
  --title "INFRA-1663: op-prod ingress serves QA's hostnames and a TLS secret it does not have" \
  --body-file "$BODY"

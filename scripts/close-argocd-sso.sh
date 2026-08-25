#!/usr/bin/env bash
# INFRA-1639 -- the closing evidence for Argo CD SSO on one on-prem cluster.
#
# Everything an acceptance criterion needs, read from the RUNNING system, in one place:
# the hostname resolves to the nodes actually running the ingressgateway, TLS is that
# cluster's own certificate, Argo serves the Entra provider, the client secret has
# content, and policy.csv can actually match a subject.
#
# What it deliberately does NOT claim: that a human can sign in. No script can. The last
# line tells you the one thing left to do by hand.
#
#   scripts/close-argocd-sso.sh op-qa
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BR="${1:-}"
case "$BR" in op-dev|op-qa|op-prod) : ;; *)
  echo "!! usage: $0 <op-dev|op-qa|op-prod>" >&2; exit 2 ;; esac
HOST="argocd.${BR}.usxpress.io"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib-onprem-ctx.sh"
onprem_resolve_ctx "$BR" || exit 1
K=(kubectl --kubeconfig="$ONPREM_KC" --context="$ONPREM_CTX")

FAIL=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1" >&2; FAIL=1; }

echo "== $BR -- https://$HOST"

# 1. DNS, and it must point at THIS cluster's ingressgateway nodes. A record that
#    resolves is not enough: op-prod's branch carried op-dev's node IPs for a month.
IPS=$(dig +short "$HOST" | sort -u)
if [ -z "$IPS" ]; then
  bad "DNS: $HOST does not resolve"
else
  NODES=$("${K[@]}" -n istio-ingress get pods -l app=istio-ingressgateway \
            -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort -u)
  WANT=""
  for n in $NODES; do
    ip=$("${K[@]}" get node "$n" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    [ -n "$ip" ] && WANT="$WANT$ip
"
  done
  WANT=$(printf '%s' "$WANT" | sort -u)
  STRAY=$(comm -23 <(printf '%s\n' $IPS) <(printf '%s\n' $WANT))
  if [ -n "$STRAY" ]; then
    bad "DNS: $(printf '%s' "$STRAY" | tr '\n' ' ')points somewhere that is not this cluster's ingressgateway"
  else
    ok "DNS: $(printf '%s\n' $IPS | wc -l) A records, all ingressgateway nodes on $BR"
  fi
fi

# 2. HTTPS, with this cluster's own certificate. --insecure would hide exactly the
#    fault that sat on op-prod for 27 days, so it is not used.
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$HOST/" 2>/dev/null)
[ "$CODE" = "200" ] && ok "HTTPS: 200, certificate validates" \
                    || bad "HTTPS: got '${CODE:-no response}' (a TLS failure reports 000)"

# 3. Argo is serving the Entra provider, not a stale or default config.
SETTINGS=$(curl -s --max-time 15 "https://$HOST/api/v1/settings" 2>/dev/null)
printf '%s' "$SETTINGS" | grep -q '"oidcConfig"' \
  && ok "provider: oidcConfig served by /api/v1/settings" \
  || bad "provider: no oidcConfig in /api/v1/settings"
printf '%s' "$SETTINGS" | grep -q 'login.microsoftonline.com' \
  && ok "provider: issuer is Entra" \
  || bad "provider: issuer is not Entra"

# 4. The client secret has CONTENT. A green ExternalSecret proves the sync ran.
for S in argocd-entra-oidc argocd-secret; do
  for KEY in client_secret oidc.entra.clientSecret; do
    V=$("${K[@]}" -n argocd get secret "$S" -o jsonpath="{.data.$KEY}" 2>/dev/null)
    [ -n "$V" ] && { N=$(printf '%s' "$V" | base64 -d | wc -c)
      [ "$N" -ge 32 ] && ok "secret: $S/$KEY holds $N bytes" \
                      || bad "secret: $S/$KEY holds only $N bytes"
      FOUND=1; break 2; }
  done
done
[ "${FOUND:-0}" = 1 ] || bad "secret: no client secret found in argocd-entra-oidc or argocd-secret"

# 5. The policy can match a subject. Delegated -- one implementation, one behaviour.
echo
bash "$SCRIPT_DIR/verify-argocd-rbac.sh" "$BR" >/dev/null 2>&1 \
  && ok "policy: internally consistent (scripts/verify-argocd-rbac.sh $BR)" \
  || bad "policy: scripts/verify-argocd-rbac.sh $BR -- run it for the reason"

echo
if [ "$FAIL" -eq 0 ]; then
  cat <<DONE
  ALL MACHINE-CHECKABLE EVIDENCE PASSES for $BR.

  What no script can establish, and what the ticket actually asks for:
    1. sign out completely, sign in at https://$HOST -- you should land with
       permissions, not an empty Applications screen
    2. have an APPLICATION-TEAM member do the same. They should see their
       Application and nothing outside the project. That is the acceptance
       test; everything above is our own access.
DONE
else
  echo "  $BR is NOT ready to close. See the FAIL lines above." >&2
  exit 1
fi

#!/usr/bin/env bash
# Check an on-prem Istio route end to end: VirtualService -> Service -> DNS -> HTTP.
#
# Written 2026-08-20 for INFRA-1622. The Argo CD route reported success at every
# layer we looked at -- PR merged, Flux Kustomization Ready, VirtualService
# present, external-dns logging "Desired change: CREATE" -- while the hostname
# resolved to nothing. Each of those is a claim about a step ADJACENT to the one
# that matters. This checks the actual steps, and diffs against a route that
# already works, because the difference is the diagnosis.
#
# READ ONLY. It creates nothing and changes nothing.
#
#   scripts/check-onprem-route.sh argocd.op-qa.usxpress.io \
#       --kubeconfig ~/.kube/op-usxpress-qa-sso.yaml --context op-usxpress-qa-sso
#
# Optional: --control <hostname>   a route known to work, for the differential.
#                                  Auto-picked from the same gateway if omitted.
set -uo pipefail

HOST=""; CONTROL=""; KUBECONFIG_ARG=""; CONTEXT_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --kubeconfig) KUBECONFIG_ARG="$2"; shift 2 ;;
    --context)    CONTEXT_ARG="$2";    shift 2 ;;
    --control)    CONTROL="$2";        shift 2 ;;
    -h|--help)    sed -n '2,18p' "$0"; exit 0 ;;
    *)            HOST="$1";           shift   ;;
  esac
done
[ -n "$HOST" ] || { echo "usage: $0 <hostname> [--kubeconfig P] [--context C] [--control H]" >&2; exit 2; }
[ -n "$CONTEXT_ARG" ] || { echo "!! refusing to run without --context: this must be pinned to one cluster" >&2; exit 2; }

k() { kubectl ${KUBECONFIG_ARG:+--kubeconfig="$KUBECONFIG_ARG"} --context "$CONTEXT_ARG" "$@"; }
command -v dig >/dev/null || { echo "!! dig not installed: sudo apt install -y dnsutils" >&2; exit 2; }

FAIL=0
say() { printf '\n== %s\n' "$*"; }
bad() { printf '   FAIL  %s\n' "$*"; FAIL=1; }
ok()  { printf '   ok    %s\n' "$*"; }

# ---- 1. the VirtualService ---------------------------------------------------
say "1. VirtualService carrying $HOST"
VS_JSON=$(k get virtualservice -A -o json 2>/dev/null \
  | jq -c --arg h "$HOST" '.items[] | select(.spec.hosts // [] | index($h))' | head -1)
if [ -z "$VS_JSON" ]; then
  bad "no VirtualService anywhere lists $HOST -- nothing routes this name"
  exit 1
fi
VS_NS=$(jq -r '.metadata.namespace' <<<"$VS_JSON")
VS_NAME=$(jq -r '.metadata.name' <<<"$VS_JSON")
GW=$(jq -r '(.spec.gateways // []) | join(",")' <<<"$VS_JSON")
ok "$VS_NS/$VS_NAME on gateway [$GW]"

TARGET=$(jq -r '.metadata.annotations["external-dns.alpha.kubernetes.io/target"] // ""' <<<"$VS_JSON")
if [ -n "$TARGET" ]; then
  ok "external-dns target annotation: $TARGET"
else
  bad "no external-dns.alpha.kubernetes.io/target annotation"
  echo "         The ingress gateway here is ClusterIP with hostNetwork, so external-dns"
  echo "         has no LoadBalancer address to derive a record target from. Every route"
  echo "         on this cluster that works supplies the target by hand."
fi

DEST=$(jq -r '.spec.http[0].route[0].destination.host // ""' <<<"$VS_JSON")
DPORT=$(jq -r '.spec.http[0].route[0].destination.port.number // ""' <<<"$VS_JSON")
ok "routes to $DEST:$DPORT"

# ---- 2. does the backend Service actually expose that port? ------------------
say "2. backend Service"
SVC_NAME=${DEST%%.*}; SVC_NS=$(cut -d. -f2 <<<"$DEST"); [ "$SVC_NS" = "$DEST" ] && SVC_NS="$VS_NS"
if PORTS=$(k -n "$SVC_NS" get svc "$SVC_NAME" -o jsonpath='{.spec.ports[*].port}' 2>/dev/null) && [ -n "$PORTS" ]; then
  if grep -qw "$DPORT" <<<"$PORTS"; then
    ok "$SVC_NS/$SVC_NAME exposes $DPORT (has: $PORTS)"
  else
    bad "$SVC_NS/$SVC_NAME does NOT expose $DPORT -- it exposes: $PORTS"
  fi
  EPS=$(k -n "$SVC_NS" get endpoints "$SVC_NAME" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
  [ -n "$EPS" ] && ok "endpoints: $EPS" || bad "$SVC_NS/$SVC_NAME has NO endpoints -- no pod is backing it"
else
  bad "Service $SVC_NS/$SVC_NAME not found"
fi

# ---- 3. DNS: authoritative first, then whatever this machine uses ------------
ZONE=$(awk -F. '{print $(NF-1)"."$NF}' <<<"$HOST")
say "3. DNS for $HOST (zone $ZONE)"
NS=$(dig +short NS "$ZONE" | head -1)
if [ -z "$NS" ]; then
  bad "cannot find the nameservers for $ZONE"
else
  ok "authoritative NS: $NS"
  AUTH=$(dig +short @"$NS" "$HOST" A 2>/dev/null | tr '\n' ' ')
  LOCAL=$(dig +short "$HOST" A 2>/dev/null | tr '\n' ' ')
  NEGTTL=$(dig +noall +authority "$HOST" 2>/dev/null | awk 'NR==1{print $2}')

  if [ -n "$AUTH" ]; then ok "authoritative answer: $AUTH"; else bad "authoritative answer: NONE -- the record is not in $ZONE"; fi
  if [ -n "$LOCAL" ]; then ok "this machine resolves: $LOCAL"; else bad "this machine resolves: NOTHING"; fi

  if [ -n "$AUTH" ] && [ -z "$LOCAL" ]; then
    echo "         >> The record EXISTS. Your resolver is serving a cached negative answer."
    echo "         >> Negative TTL on the SOA: ${NEGTTL:-unknown}s. Wait it out, or use"
    echo "         >>   curl --resolve $HOST:443:${AUTH%% *} https://$HOST/"
    echo "         >> WSL forwards to the Windows host resolver, which caches separately:"
    echo "         >>   ipconfig /flushdns   (from Windows)"
  fi
fi

# ---- 4. HTTP, separating "did not resolve" from "did not connect" ------------
say "4. HTTP"
CODE=$(curl -sk -m 8 -o /dev/null -w '%{http_code}' "https://$HOST/" 2>/dev/null)
printf '   plain          : %s\n' "$CODE"
[ "$CODE" = "000" ] && echo "         (000 means curl never got a response -- could be DNS OR connect. See below.)"
if [ -n "${AUTH:-}" ]; then
  for ip in $AUTH; do
    C=$(curl -sk -m 8 -o /dev/null -w '%{http_code}' --resolve "$HOST:443:$ip" "https://$HOST/" 2>/dev/null)
    printf '   via %-14s : %s\n' "$ip" "$C"
    [ "$C" != "000" ] && [ "$CODE" = "000" ] && \
      echo "         >> Routing works. The ONLY broken link is name resolution on this machine."
  done
fi

# ---- 5. differential against a route that already works ----------------------
if [ -z "$CONTROL" ] && [ -n "$GW" ]; then
  CONTROL=$(k get virtualservice -A -o json 2>/dev/null | jq -r --arg g "${GW%%,*}" --arg h "$HOST" '
    .items[] | select((.spec.gateways // []) | index($g))
    | select(.metadata.annotations["external-dns.alpha.kubernetes.io/target"] != null)
    | (.spec.hosts // [])[] | select(. != $h)' | head -1)
fi
if [ -n "$CONTROL" ]; then
  say "5. control: $CONTROL (same gateway, known to work)"
  C_AUTH=$(dig +short @"${NS:-8.8.8.8}" "$CONTROL" A 2>/dev/null | tr '\n' ' ')
  C_LOCAL=$(dig +short "$CONTROL" A 2>/dev/null | tr '\n' ' ')
  C_CODE=$(curl -sk -m 8 -o /dev/null -w '%{http_code}' "https://$CONTROL/" 2>/dev/null)
  printf '   authoritative: %s\n   this machine : %s\n   http         : %s\n' \
    "${C_AUTH:-NONE}" "${C_LOCAL:-NONE}" "$C_CODE"
  if [ -z "${LOCAL:-}" ] && [ -n "$C_LOCAL" ]; then
    echo "         >> The control resolves here and $HOST does not, on the same resolver."
    echo "         >> That rules out split-horizon DNS and points at the record itself."
  fi
  if [ -z "${LOCAL:-}" ] && [ -z "$C_LOCAL" ]; then
    echo "         >> Neither resolves here, but the control is known to work."
    echo "         >> Suspect THIS MACHINE's resolver, not the cluster."
  fi
else
  say "5. control: none found (no other annotated route on this gateway)"
fi

say "verdict"
[ "$FAIL" = 0 ] && echo "   every checked link holds." || echo "   at least one link is broken -- see FAIL lines above."
exit "$FAIL"

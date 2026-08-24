#!/usr/bin/env bash
# Read-only ingress audit of an on-prem Talos cluster, resolved BY ENDPOINT.
#
# Why this is a script and not a pasted command: on 2026-08-24 a pasted
#   export KUBECONFIG=$HOME/.kube/<the file the loop printed>
# died on a bash syntax error. A failed export leaves KUBECONFIG at its PREVIOUS
# value, so the next four commands ran against op-dev while being labelled
# "prod". Same trap as 2026-07-24. There is no placeholder here to get wrong,
# and the cluster identity is asserted twice before anything is read.
#
#   scripts/onprem-ingress-audit.sh --cluster op-prod
set -euo pipefail

CLUSTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cluster) CLUSTER="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$CLUSTER" in
  op-dev)  ENDPOINT="10.10.82.50" ;;
  op-qa)   ENDPOINT="10.10.82.51" ;;
  op-prod) ENDPOINT="10.10.82.52" ;;
  *) echo "!! --cluster must be op-dev, op-qa or op-prod (got '${CLUSTER:-}')" >&2; exit 2 ;;
esac
command -v jq >/dev/null || { echo "!! jq not on PATH" >&2; exit 2; }

echo "== ingress audit: $CLUSTER  (must be https://$ENDPOINT:6443)"
echo

# 1. Resolve. Never trust a filename -- match on the server address. A merged
#    multi-cluster file is fine as long as we pin the CONTEXT, not just the file.
FOUND=""
for f in "$HOME"/.kube/*.yaml "$HOME"/.kube/config; do
  [ -f "$f" ] || continue
  J=$(kubectl --kubeconfig="$f" config view -o json 2>/dev/null) || continue
  CTXS=$(printf '%s' "$J" | jq -r --arg ep "$ENDPOINT" '
    [.clusters[] | select(.cluster.server | contains($ep)) | .name] as $c
    | .contexts[] | select(.context.cluster as $n | $c | index($n)) | .name' 2>/dev/null) || continue
  for c in $CTXS; do
    printf '   candidate: %-40s context=%s\n' "$(basename "$f")" "$c"
    FOUND="$FOUND$f|$c
"
  done
done

N=$(printf '%s' "$FOUND" | grep -c . || true)
if [ "$N" -eq 0 ]; then
  echo "!! no kubeconfig under ~/.kube serves https://$ENDPOINT:6443"
  echo "   Check the corp VPN first:  nc -vz -w 5 $ENDPOINT 6443"
  exit 2
fi

KC=$(printf '%s' "$FOUND" | head -1 | cut -d'|' -f1)
CTX=$(printf '%s' "$FOUND" | head -1 | cut -d'|' -f2)
[ "$N" -eq 1 ] || echo "   ($N candidates; using the first)"
echo "   using: $KC  context=$CTX"

# 2. Assert the pinned context really resolves to the endpoint. Config-level.
SRV=$(kubectl --kubeconfig="$KC" --context="$CTX" config view --minify \
        -o jsonpath='{.clusters[0].cluster.server}')
[ "$SRV" = "https://$ENDPOINT:6443" ] || {
  echo "!! context '$CTX' resolves to $SRV, not https://$ENDPOINT:6443. Refusing." >&2
  exit 2
}

K() { kubectl --kubeconfig="$KC" --context="$CTX" "$@"; }

# 3. Assert against the LIVE cluster. A config file can say anything; node names
#    are stamped by the cluster itself and carry the cluster's short name.
NODE=$(K get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || {
  echo "!! cannot reach $ENDPOINT. VPN? SSO session?" >&2; exit 2; }
case "$NODE" in
  *"$CLUSTER"*) echo "   live check: first node '$NODE' -- matches $CLUSTER" ;;
  *) echo "!! live node '$NODE' does not carry '$CLUSTER'. Wrong cluster. Refusing." >&2; exit 2 ;;
esac
echo

echo "-- istio ingressgateway pods (their node IPs are what external-dns must target) --"
K -n istio-ingress get pods -o wide -l app=istio-ingressgateway
echo
echo "-- node InternalIPs of those nodes --"
K get nodes -o custom-columns=NAME:.metadata.name,IP:.status.addresses[?\(@.type==\"InternalIP\"\)].address
echo
echo "-- istio Gateways (networking.istio.io, NOT gateway.networking.k8s.io) --"
K get gateway.networking.istio.io -A -o json \
  | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)\n" +
      ( [.spec.servers[] | "    port \(.port.number)/\(.port.protocol)  hosts=\(.hosts|join(","))  cred=\(.tls.credentialName // "-")"] | join("\n") )'
echo
echo "-- every VirtualService and the hostnames it claims --"
K get virtualservice -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,HOSTS:.spec.hosts
echo
echo "-- TLS secrets in istio-ingress --"
K -n istio-ingress get secret --field-selector type=kubernetes.io/tls \
  -o custom-columns=NAME:.metadata.name,AGE:.metadata.creationTimestamp
echo
echo "-- hostname suffixes claimed here (should all be .$CLUSTER.usxpress.io) --"
K get virtualservice -A -o json \
  | jq -r '[.items[].spec.hosts[]] | map(sub("^[^.]+\\.";"")) | group_by(.) | map("   \(length)  \(.[0])") | .[]'

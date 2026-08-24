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

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-onprem-ctx.sh"
onprem_resolve_ctx "$CLUSTER"
K() { kubectl --kubeconfig="$ONPREM_KC" --context="$ONPREM_CTX" "$@"; }

echo "== ingress audit: $CLUSTER  ($ONPREM_ENDPOINT, node $ONPREM_NODE)"
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

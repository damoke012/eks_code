#!/usr/bin/env bash
# Resolve an on-prem Talos cluster BY ENDPOINT, never by a filename or a pasted path.
#
# Sets ONPREM_KC and ONPREM_CTX, or exits non-zero with a reason. Asserts twice: the
# pinned context's server string, then a LIVE node name carrying the cluster's short
# name -- a config file can claim anything.
#
# Why: on 2026-08-24 a pasted `export KUBECONFIG=$HOME/.kube/<placeholder>` died on a
# syntax error, leaving KUBECONFIG at its previous value, and four commands labelled
# "prod" ran against op-dev. Same trap as 2026-07-24.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib-onprem-ctx.sh"
#   onprem_resolve_ctx op-prod
#   kubectl --kubeconfig="$ONPREM_KC" --context="$ONPREM_CTX" get nodes

onprem_endpoint_for() {
  case "$1" in
    op-dev)  echo "10.10.82.50" ;;
    op-qa)   echo "10.10.82.51" ;;
    op-prod) echo "10.10.82.52" ;;
    *) return 1 ;;
  esac
}

onprem_resolve_ctx() {
  local cluster="${1:-}" endpoint found n kc ctx srv node
  endpoint=$(onprem_endpoint_for "$cluster") || {
    echo "!! cluster must be op-dev, op-qa or op-prod (got '${cluster}')" >&2; return 2; }
  command -v jq >/dev/null || { echo "!! jq not on PATH" >&2; return 2; }

  found=""
  for f in "$HOME"/.kube/*.yaml "$HOME"/.kube/config; do
    [ -f "$f" ] || continue
    local j ctxs
    j=$(kubectl --kubeconfig="$f" config view -o json 2>/dev/null) || continue
    ctxs=$(printf '%s' "$j" | jq -r --arg ep "$endpoint" '
      [.clusters[] | select(.cluster.server | contains($ep)) | .name] as $c
      | .contexts[] | select(.context.cluster as $n | $c | index($n)) | .name' 2>/dev/null) || continue
    for c in $ctxs; do found="$found$f|$c
"; done
  done

  n=$(printf '%s' "$found" | grep -c . || true)
  if [ "$n" -eq 0 ]; then
    echo "!! no kubeconfig under ~/.kube serves https://$endpoint:6443 ($cluster)" >&2
    echo "   Check the corp VPN:  nc -vz -w 5 $endpoint 6443" >&2
    if [ "$cluster" = "op-prod" ]; then
      echo "   NOTE: op-prod has had no persisted kubeconfig since at least 2026-08-24." >&2
      echo "   Reaching it means regenerating credentials first (INFRA-1663)." >&2
    fi
    return 2
  fi

  kc=$(printf '%s' "$found" | head -1 | cut -d'|' -f1)
  ctx=$(printf '%s' "$found" | head -1 | cut -d'|' -f2)
  [ "$n" -eq 1 ] || echo "   ($n candidates for $cluster; using $(basename "$kc") / $ctx)" >&2

  srv=$(kubectl --kubeconfig="$kc" --context="$ctx" config view --minify \
          -o jsonpath='{.clusters[0].cluster.server}')
  [ "$srv" = "https://$endpoint:6443" ] || {
    echo "!! context '$ctx' resolves to $srv, not https://$endpoint:6443. Refusing." >&2
    return 2; }

  node=$(kubectl --kubeconfig="$kc" --context="$ctx" get nodes \
           -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || {
    echo "!! cannot reach $endpoint ($cluster). VPN? SSO session?" >&2; return 2; }
  case "$node" in
    *"$cluster"*) : ;;
    *) echo "!! live node '$node' does not carry '$cluster'. Wrong cluster. Refusing." >&2
       return 2 ;;
  esac

  ONPREM_KC="$kc"; ONPREM_CTX="$ctx"; ONPREM_NODE="$node"; ONPREM_ENDPOINT="$endpoint"
  export ONPREM_KC ONPREM_CTX ONPREM_NODE ONPREM_ENDPOINT
}

#!/usr/bin/env bash
# Run kubectl against an on-prem cluster resolved BY ENDPOINT, never by whatever the
# default kubeconfig happens to hold.
#
#   bash scripts/kq.sh qa -n app-risingwave get job etl-pipeline-apply
#   bash scripts/kq.sh dev get nodes
#
# Prints which cluster it resolved to before running, so the output is never ambiguous.
set -uo pipefail
ENV_ARG="${1:-}"; shift || true
case "$ENV_ARG" in
  dev|qa|prod) ;;
  *) echo "usage: bash scripts/kq.sh dev|qa|prod <kubectl args...>"; exit 2 ;;
esac
[ $# -eq 0 ] && { echo "no kubectl arguments given"; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$(python3 "$HERE/kube-resolve-onprem.py" "$ENV_ARG")" || {
  echo "No kubeconfig on this machine serves on-prem $ENV_ARG."; exit 4; }
KCFG="$(printf '%s' "$R" | cut -f1)"; CTX="$(printf '%s' "$R" | cut -f2)"; SRV="$(printf '%s' "$R" | cut -f3)"
echo "# op-usxpress-$ENV_ARG  ->  $CTX  ($SRV)" >&2
KUBECONFIG="$KCFG" exec kubectl --context "$CTX" "$@"

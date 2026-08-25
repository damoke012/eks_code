#!/usr/bin/env bash
# Run kubectl against an on-prem Talos cluster, resolved BY ENDPOINT.
#
# Why this exists: `kubectl --context op-usxpress-prod ...` is not a runnable command on
# this workstation. ~/.kube churns -- contexts vanish, files get rotated to .bak, op-prod
# has been rebuilt from its talosconfig -- so a hard-coded context name fails outright
# (best case) or resolves to a DIFFERENT cluster than the label claims (worst case, and
# it has happened: four commands labelled "prod" ran against op-dev on 2026-08-24).
#
# Handing over a raw --context has now produced three unrunnable commands. This wrapper
# is the fix: the cluster is named ONCE, as an endpoint-verified argument, and every
# kubectl flag after `--` is passed through untouched.
#
#   scripts/onprem-kubectl.sh op-prod -- -n istio-ingress get challenges
#   scripts/onprem-kubectl.sh op-qa   -- -n argocd get cm argocd-rbac-cm -o yaml
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BR="${1:-}"; shift || true
[ "${1:-}" = "--" ] && shift || true
case "$BR" in op-dev|op-qa|op-prod) : ;; *)
  echo "!! usage: $0 <op-dev|op-qa|op-prod> -- <kubectl args...>" >&2; exit 2 ;; esac
[ $# -gt 0 ] || { echo "!! no kubectl arguments given" >&2; exit 2; }

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib-onprem-ctx.sh"
if ! onprem_resolve_ctx "$BR"; then
  if [ "$BR" = "op-prod" ]; then
    echo "   op-prod's kubeconfig is REBUILDABLE from its talosconfig -- it is not lost:" >&2
    echo "     bash $SCRIPT_DIR/onprem-prod-kubeconfig.sh" >&2
  fi
  exit 1
fi
exec kubectl --kubeconfig="$ONPREM_KC" --context="$ONPREM_CTX" "$@"

#!/usr/bin/env bash
# Run flux against an on-prem Talos cluster, resolved BY ENDPOINT.
#
# Same reason onprem-kubectl.sh exists: `flux ... --context admin@op-usxpress-prod` is
# not a runnable command on this workstation, and a hard-coded context name either fails
# or resolves to a DIFFERENT cluster than the label claims.
#
#   scripts/onprem-flux.sh op-prod -- reconcile kustomization flux-system --with-source
#   scripts/onprem-flux.sh op-prod -- get kustomizations
#
# Note on --with-source: it is a flag of `flux reconcile kustomization` / `helmrelease`.
# `flux reconcile source git <name>` does not take it and errors with "unknown flag" —
# that subcommand IS the source refresh. To pull a merge through end to end:
#
#   scripts/onprem-flux.sh op-prod -- reconcile kustomization flux-system --with-source
#
# which refreshes the GitRepository first, then re-applies the Kustomization.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BR="${1:-}"; shift || true
[ "${1:-}" = "--" ] && shift || true
case "$BR" in op-dev|op-qa|op-prod) : ;; *)
  echo "!! usage: $0 <op-dev|op-qa|op-prod> -- <flux args...>" >&2; exit 2 ;; esac
[ $# -gt 0 ] || { echo "!! no flux arguments given" >&2; exit 2; }

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib-onprem-ctx.sh"
if ! onprem_resolve_ctx "$BR"; then
  if [ "$BR" = "op-prod" ]; then
    echo "   op-prod's kubeconfig is REBUILDABLE from its talosconfig -- it is not lost:" >&2
    echo "     bash $SCRIPT_DIR/onprem-prod-kubeconfig.sh" >&2
  fi
  exit 1
fi
exec flux --kubeconfig="$ONPREM_KC" --context="$ONPREM_CTX" "$@"

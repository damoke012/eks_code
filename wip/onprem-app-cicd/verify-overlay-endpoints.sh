#!/usr/bin/env bash
# Resolve every hostname an overlay names against the cluster it targets, BEFORE
# the PR merges.
#
# Why this exists: deploy/overlays/qa/endpoints.yaml shipped with
# `postgres-postgresql.risingwave.svc.cluster.local`, a dev service name. QA runs
# `pg-postgresql`. Nothing catches that until the Job runs and psql reports
# "Name does not resolve" -- by which point a sync has already failed.
#
# Fourth instance of the same family: IRSA role ARNs on all three platform
# branches, RisingWave L4 routes on op-qa, the ApplicationSet's targetRevision,
# and now this. A scaffolded file inherits the source environment's identifiers
# and nothing reads them until runtime.
#
# Usage:
#   ./verify-overlay-endpoints.sh deploy/overlays/qa/endpoints.yaml op-usxpress-qa-sso
set -euo pipefail

FILE="${1:?usage: $0 <endpoints.yaml> <kube-context>}"
CTX="${2:?usage: $0 <endpoints.yaml> <kube-context>}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/op-usxpress-qa-sso.yaml}"
export KUBECONFIG

fail=0
# every *.svc.cluster.local host named in the file, with the key that names it
grep -oE '^ *[A-Z_]+: *[a-z0-9.-]+\.svc\.cluster\.local' "$FILE" | while read -r line; do
  key="${line%%:*}"; key="${key// /}"
  host="${line##*: }"
  svc="${host%%.*}"
  ns=$(printf '%s' "$host" | cut -d. -f2)
  if kubectl --context "$CTX" -n "$ns" get svc "$svc" >/dev/null 2>&1; then
    port=$(kubectl --context "$CTX" -n "$ns" get svc "$svc" \
             -o jsonpath='{.spec.ports[*].port}' 2>/dev/null)
    printf '  ✓ %-10s %s  (ports: %s)\n' "$key" "$host" "$port"
  else
    printf '  ✗ %-10s %s  — NO SUCH SERVICE in namespace %s\n' "$key" "$host" "$ns"
    printf '    candidates:\n'
    kubectl --context "$CTX" -n "$ns" get svc -o name 2>/dev/null | sed 's|^|      |'
    fail=1
  fi
done

# subshell above cannot set fail; re-check by counting misses
misses=$(grep -oE '^ *[A-Z_]+: *[a-z0-9.-]+\.svc\.cluster\.local' "$FILE" | while read -r line; do
  host="${line##*: }"; svc="${host%%.*}"; ns=$(printf '%s' "$host" | cut -d. -f2)
  kubectl --context "$CTX" -n "$ns" get svc "$svc" >/dev/null 2>&1 || echo x
done | wc -l)

if [ "$misses" -gt 0 ]; then
  echo
  echo "  $misses hostname(s) do not resolve on $CTX. Fix the overlay before merging."
  exit 1
fi
echo
echo "  all hostnames resolve on $CTX"

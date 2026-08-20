#!/usr/bin/env bash
# Does anything actually listen where each Service sends traffic?
#
# INFRA-1654, 2026-08-20. ghostunnel-rw-postgres ran `--listen=:4567` behind a
# Service that is `5432 -> targetPort 5432`. Nothing was listening on 5432. Both
# pods reported READY true with 0 restarts, because the readiness probe was
# tcpSocket on the *status* port (9090). It survived eleven weeks on two clusters.
#
# Kubernetes cannot catch this: a NUMERIC targetPort needs no matching
# containerPort, so a Service may point at a port nothing binds and no controller
# objects. Endpoints existing proves a pod passed *its own* probe, not that the
# routed port answers.
#
# This connects. For every Service port it opens a port-forward and attempts a
# TCP connection, which is the only evidence that settles it.
#
# READ ONLY — port-forward creates no workload and changes no object.
#
#   scripts/check-service-ports-listening.sh risingwave --context op-usxpress-qa-sso
#   scripts/check-service-ports-listening.sh risingwave --context op-usxpress-qa-sso \
#       --kubeconfig ~/.kube/op-usxpress-qa-sso.yaml
set -uo pipefail

NS=""; CTX=""; KCFG=""; SKIP_METRICS=1
while [ $# -gt 0 ]; do
  case "$1" in
    --context)      CTX="$2";  shift 2 ;;
    --kubeconfig)   KCFG="$2"; shift 2 ;;
    --all-ports)    SKIP_METRICS=0; shift ;;
    -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
    -*)             echo "unknown flag: $1" >&2; exit 2 ;;
    *)              NS="$1";   shift ;;
  esac
done
[ -n "$NS" ]  || { echo "usage: $0 <namespace> --context <ctx> [--kubeconfig P] [--all-ports]" >&2; exit 2; }
[ -n "$CTX" ] || { echo "!! refusing to run without --context: this must be pinned to one cluster" >&2; exit 2; }

k() { kubectl ${KCFG:+--kubeconfig="$KCFG"} --context "$CTX" "$@"; }

command -v jq >/dev/null || { echo "!! jq not installed" >&2; exit 2; }
k get ns "$NS" >/dev/null 2>&1 || { echo "!! namespace $NS not found in context $CTX" >&2; exit 1; }

echo "namespace $NS on context $CTX"
echo
printf '%-34s %-7s %-9s %-9s %s\n' SERVICE PORT TARGET ENDPOINTS LISTENING
printf '%-34s %-7s %-9s %-9s %s\n' "-------" "----" "------" "---------" "---------"

FAIL=0
LOCAL=45000

while IFS=$'\t' read -r SVC PORT TARGET PNAME; do
  # metrics/admin ports are frequently a different listener by design; the point
  # of this check is the port that carries traffic
  if [ "$SKIP_METRICS" = 1 ]; then
    case "$PNAME" in metrics|status|admin|telemetry|health) continue ;; esac
  fi

  EPS=$(k -n "$NS" get endpoints "$SVC" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w)
  if [ "$EPS" -eq 0 ]; then
    printf '%-34s %-7s %-9s %-9s %s\n' "$SVC" "$PORT" "$TARGET" "0" "SKIP — no endpoints"
    continue
  fi

  LOCAL=$((LOCAL + 1))
  k -n "$NS" port-forward "svc/$SVC" "$LOCAL:$PORT" >/dev/null 2>&1 &
  PF=$!
  RESULT="no"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if (exec 3<>/dev/tcp/127.0.0.1/$LOCAL) 2>/dev/null; then RESULT="yes"; exec 3<&- 3>&-; break; fi
    sleep 0.4
  done
  kill "$PF" 2>/dev/null; wait "$PF" 2>/dev/null

  if [ "$RESULT" = yes ]; then
    printf '%-34s %-7s %-9s %-9s %s\n' "$SVC" "$PORT" "$TARGET" "$EPS" "yes"
  else
    printf '%-34s %-7s %-9s %-9s %s\n' "$SVC" "$PORT" "$TARGET" "$EPS" "NO — nothing bound"
    FAIL=1
  fi
done < <(k -n "$NS" get svc -o json | jq -r '
  .items[] | .metadata.name as $n |
  .spec.ports[]? | [$n, (.port|tostring), (.targetPort|tostring), (.name // "")] | @tsv')

echo
if [ "$FAIL" = 0 ]; then
  echo "every routed Service port accepted a connection."
else
  echo "A 'NO' row means the Service has healthy endpoints and still routes to a port"
  echo "nothing binds. Compare the Service's targetPort against the container's listen"
  echo "flag, and check whether the readinessProbe is watching a different port:"
  echo "  kubectl --context $CTX -n $NS get deploy <name> \\"
  echo "      -o jsonpath='{.spec.template.spec.containers[0].args}{\"\\n\"}{.spec.template.spec.containers[0].readinessProbe}{\"\\n\"}'"
fi
exit "$FAIL"

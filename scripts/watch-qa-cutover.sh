#!/usr/bin/env bash
# Watch the QA cutover land after #22. Read-only.
#   bash scripts/watch-qa-cutover.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K() { bash "$HERE/kq.sh" qa "$@" 2>/dev/null; }
NS="-n app-risingwave"

for i in $(seq 1 12); do
  echo "=========== $(date -u '+%H:%M:%SZ')   poll $i/12 ==========="
  printf 'ExternalSecret : '
  K $NS get externalsecret etl-pipeline-credentials \
     -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason} {end}{"\n"}' || echo "(unreadable)"
  printf 'Secret keys    : '
  K $NS get secret etl-pipeline-credentials \
     -o go-template='{{range $k,$v := .data}}{{$k}} {{end}}{{"\n"}}' || echo "(absent)"
  echo "Jobs/pods:"
  K $NS get job,pods | sed 's/^/   /'
  IMG="$(K $NS get pods -o jsonpath='{.items[*].spec.containers[*].image}')"
  [ -n "$IMG" ] && echo "image          : $IMG"

  POD="$(K $NS get pods -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{"\n"}{end}' | awk '$2=="Running"||$2=="Succeeded"||$2=="Failed"{print $1; exit}')"
  if [ -n "${POD:-}" ]; then
    echo
    echo "--- pod $POD reached a real phase; its logs -------------------------"
    K $NS logs "$POD" --tail=60 | sed 's/^/   /'
    echo
    echo "That is the cutover's own output. A refusal naming %KAFKA_...% tokens is"
    echo "the EXPECTED result -- the wedge became visible. A success would mean the"
    echo "tokens were substituted blank, which is worse: check the log before cheering."
    exit 0
  fi
  sleep 15
done
echo
echo "No pod reached Running/Succeeded/Failed in 3 minutes. Argo may not have synced yet:"
echo "   bash scripts/kq.sh qa -n argocd get application -o wide"

#!/usr/bin/env bash
# Do this cluster's alerts reach anyone, and can each rule actually fire?
#
# On op-usxpress-dev, 2026-08-21: ~40 well-written rules, 54 alerts firing, no
# Alertmanager, and every Flux rule permanently inactive because nothing scrapes
# flux-system. Two Kustomizations sat Ready=False for 2d18h. The cluster had
# correctly diagnosed the cause 76 seconds in, and told nobody.
#
# Three questions, none of which any status field answers:
#   1. Is there anywhere for a firing alert to GO?
#   2. Does each rule's metric EXIST? A PromQL expression selecting zero series
#      is valid, healthy, inactive, and dead. Nothing reports this as an error.
#   3. What is firing now, and for how long? A two-month-old alert is either an
#      outage nobody noticed or noise that will drown the channel on day one.
#
# READ ONLY. Creates no workload (CLAUDE.md rule 3) — it port-forwards to the
# existing Prometheus and queries its HTTP API.
#
#   scripts/check-alert-delivery.sh --context admin@op-usxpress-dev
#   scripts/check-alert-delivery.sh --kubeconfig ~/.kube/op-usxpress-qa-sso.yaml \
#       --context op-usxpress-qa-sso
#
# Exit 0 = alerts are delivered and every rule's metric exists.
#      1 = a real gap.  2 = could not be determined.
set -uo pipefail

CTX=""; KCFG=""; NS="prometheus"; PORT=9099
while [ $# -gt 0 ]; do
  case "$1" in
    --context)    CTX="$2";  shift 2 ;;
    --kubeconfig) KCFG="$2"; shift 2 ;;
    --namespace)  NS="$2";   shift 2 ;;
    --port)       PORT="$2"; shift 2 ;;
    -h|--help)    sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$CTX" ] || { echo "usage: $0 --context <ctx> [--kubeconfig P] [--namespace N]" >&2; exit 2; }

k() { kubectl ${KCFG:+--kubeconfig="$KCFG"} --context "$CTX" "$@"; }
for t in jq curl; do command -v "$t" >/dev/null || { echo "!! $t not installed" >&2; exit 2; }; done

FAIL=0; UNKNOWN=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
unkn() { printf '  \033[33m????\033[0m  %s\n' "$1"; UNKNOWN=$((UNKNOWN+1)); }
note() { printf '        %s\n' "$1"; }

echo "=== alert delivery: $CTX ==="
echo

# ------------------------------------------------------- 1. is there a sink --
echo "Delivery — is there anywhere for a firing alert to go?"
PROM=$(k -n "$NS" get prometheus -o json 2>/dev/null)
if [ -z "$PROM" ]; then
  unkn "no Prometheus CR readable in namespace $NS"
else
  ALERTING=$(printf '%s' "$PROM" | jq -r '[.items[].spec.alerting // empty] | length')
  if [ "${ALERTING:-0}" -gt 0 ]; then
    pass "Prometheus CR has .spec.alerting configured"
    printf '%s' "$PROM" | jq -r '.items[].spec.alerting.alertmanagers[]?
      | "        -> \(.namespace)/\(.name):\(.port)"'
  else
    fail "Prometheus CR has NO .spec.alerting — firing alerts go nowhere"
    note "kube-prometheus-stack values likely carry alertmanager.enabled: false"
  fi
fi
AMPODS=$(k -n "$NS" get pods -o json 2>/dev/null \
         | jq -r '[.items[] | select(.metadata.name | test("alertmanager"))] | length')
if [ "${AMPODS:-0}" -gt 0 ]; then pass "$AMPODS alertmanager pod(s) present"
else fail "no alertmanager pod in $NS"; fi
echo

# ------------------------------------------------- port-forward to Prometheus -
SVC=$(k -n "$NS" get svc -o json 2>/dev/null \
      | jq -r '[.items[] | select(.spec.ports[]?.name == "http-web" or .spec.ports[]?.port == 9090)
               | .metadata.name] | .[0] // empty')
if [ -z "$SVC" ]; then
  unkn "no Prometheus service found in $NS — rule and alert checks skipped"
  echo; echo "=== $CTX ==="; echo "Could not reach Prometheus. Not a pass."; exit 2
fi
PFLOG=$(mktemp); trap 'kill "${PFPID:-0}" 2>/dev/null; rm -f "$PFLOG"' EXIT
k -n "$NS" port-forward "svc/$SVC" "$PORT:9090" >"$PFLOG" 2>&1 &
PFPID=$!
API="http://127.0.0.1:$PORT/api/v1"
# kubectl binds the LOCAL socket before contacting the pod, so a successful
# connect proves only that kubectl started. Wait for a real API answer instead.
READY=no
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 1
  if curl -sf --max-time 2 "$API/status/runtimeinfo" >/dev/null 2>&1; then READY=yes; break; fi
done
if [ "$READY" != "yes" ]; then
  unkn "could not reach the Prometheus API through port-forward: $(head -2 "$PFLOG" | tr '\n' ' ')"
  echo; echo "=== $CTX ==="; echo "Could not query Prometheus. Not a pass."; exit 2
fi

q() { curl -s --max-time 10 --get --data-urlencode "query=$1" "$API/query"; }

# --------------------------------------------- 2. can each rule ever fire? ----
# The core check. A rule whose expression selects a metric that is never
# ingested is valid, healthy, inactive and useless, and NOTHING in the stack
# reports it. Pull the metric names out of every alert expression and ask
# Prometheus whether each one exists.
echo "Rules — does each alert's metric actually exist?"
RULES=$(curl -s --max-time 15 "$API/rules" 2>/dev/null)
if [ -z "$RULES" ]; then
  unkn "could not read /api/v1/rules"
else
  # Only PromQL keywords survive the stripping below; everything else that is
  # left is a metric name. Label names are NOT in this list on purpose — they
  # are removed with their braces rather than enumerated, because every rule
  # invents new ones (ceph_daemon, persistentvolumeclaim, condition, ...) and a
  # list of them would go stale and start reporting live rules as dead.
  RESERVED='^(by|without|on|ignoring|group_left|group_right|offset|bool|and|or|unless|inf|nan|le'
  RESERVED+='|sum|min|max|avg|group|stddev|stdvar|count|count_values|bottomk|topk|quantile)$'

  DEAD=0; LIVE=0
  while IFS='|' read -r GROUP ALERT EXPR; do
    [ -n "$ALERT" ] || continue
    # Strip, in order: aggregation clauses `by (...)` / `without (...)` — whose
    # grouping labels sit in PARENTHESES, not braces, and so survive everything
    # else; then label matchers {...}, quoted strings, range selectors [5m], and
    # every function call `name(`. What remains is metric names and keywords.
    CLEAN=$(printf '%s' "$EXPR" \
      | sed 's/\b\(by\|without\)[[:space:]]*([^)]*)//g' \
      | sed 's/{[^}]*}//g; s/"[^"]*"//g; s/\[[^]]*\]//g; s/[a-zA-Z_:][a-zA-Z0-9_:]*(/ (/g')
    METRICS=$(printf '%s' "$CLEAN" \
      | grep -oE '[a-zA-Z_:][a-zA-Z0-9_:]*' | sort -u \
      | grep -vE "$RESERVED" || true)
    MISSING=""
    for M in $METRICS; do
      N=$(q "count($M)" | jq -r '.data.result | length' 2>/dev/null)
      [ "${N:-0}" = "0" ] && MISSING="$MISSING $M"
    done
    if [ -n "$MISSING" ]; then
      fail "$GROUP / $ALERT — can never fire"
      note "no series for:$MISSING"
      DEAD=$((DEAD+1))
    else
      LIVE=$((LIVE+1))
    fi
  done < <(printf '%s' "$RULES" | jq -r '.data.groups[] | .name as $g
      | (.rules[] | select(.type=="alerting"))
      | "\($g)|\(.name)|\(.query | gsub("\n"; " "))"')
  echo "  $LIVE rule(s) have live metrics, $DEAD cannot fire."
fi
echo

# ------------------------------------------------------- 3. what is firing ----
echo "Firing now — and for how long"
ALERTS=$(curl -s --max-time 10 "$API/alerts" 2>/dev/null)
if [ -z "$ALERTS" ]; then
  unkn "could not read /api/v1/alerts"
else
  N=$(printf '%s' "$ALERTS" | jq -r '[.data.alerts[] | select(.state=="firing")] | length')
  echo "  $N firing"
  printf '%s' "$ALERTS" | jq -r '[.data.alerts[] | select(.state=="firing")]
    | group_by(.labels.alertname)
    | map({name: .[0].labels.alertname, n: length, oldest: (map(.activeAt) | sort | .[0])})
    | sort_by(.oldest)[]
    | "    \(.oldest[0:10])  \(.name)  x\(.n)"'
  # An alert older than a week is either an outage nobody noticed or noise that
  # will drown the channel the day delivery is switched on. Either way it has to
  # be triaged BEFORE delivery, not after.
  WEEK=$(( $(date -u +%s) - 604800 ))
  STALE=$(printf '%s' "$ALERTS" | jq -r --argjson w "$WEEK" \
    '[.data.alerts[] | select(.state=="firing")
      | select((.activeAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) < $w)] | length' 2>/dev/null)
  if [ "${STALE:-0}" -gt 0 ]; then
    fail "$STALE alert(s) have been firing for over a week"
    note "triage these BEFORE enabling delivery — an unreviewed backlog trains everyone to ignore the channel"
  fi
fi

echo
echo "=== $CTX ==="
if [ "$FAIL" -gt 0 ]; then
  echo "FAILED: $FAIL check(s). UNKNOWN: $UNKNOWN."; exit 1
elif [ "$UNKNOWN" -gt 0 ]; then
  echo "No failures, but $UNKNOWN check(s) could NOT be made. This is not a pass."; exit 2
fi
echo "Alerts are delivered, and every rule's metric exists."

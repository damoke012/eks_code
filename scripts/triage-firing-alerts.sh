#!/usr/bin/env bash
# INFRA-1658 -- dump every firing alert with its age, so the 54 can be triaged
# from data rather than from memory.
#
# Groups by alertname, prints how long each instance has been firing, and marks
# whether the rule is ours (a platform-* PrometheusRule) or a kube-prometheus-stack
# default -- because the two need different decisions. Ours we fix or delete;
# theirs we usually silence or correct for Talos.
#
# ASSERTS PROMETHEUS ACTUALLY ANSWERED. On 2026-08-24 a verification loop ran
# against a dead port-forward and printed "(none)", which reads as "no alerts"
# and looks like a clean result. An empty answer and no answer are different
# things, and this refuses to conflate them.
#
#   scripts/triage-firing-alerts.sh --context admin@op-usxpress-dev
#   scripts/triage-firing-alerts.sh --context admin@op-usxpress-qa --namespace monitoring
set -uo pipefail

CTX=""; NS="prometheus"; SVC="prometheus-stack-kube-prom-prometheus"; PORT=9090
while [ $# -gt 0 ]; do
  case "$1" in
    --context) CTX="$2"; shift 2 ;;
    --namespace) NS="$2"; shift 2 ;;
    --service) SVC="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$CTX" ] || { echo "!! --context is required (CLAUDE.md rule 2)" >&2; exit 2; }
command -v jq >/dev/null || { echo "!! jq not on PATH" >&2; exit 2; }

echo "== firing alerts on $CTX  (ns/$NS svc/$SVC:$PORT)"

# Find a free local port rather than assuming 9090 is free. A stale forward from
# an earlier run silently serves the OLD cluster, which is worse than failing.
LP=0
for p in $(seq 19090 19110); do
  if ! (exec 3<>/dev/tcp/127.0.0.1/"$p") 2>/dev/null; then LP=$p; break; fi
done
[ "$LP" -ne 0 ] || { echo "!! no free local port in 19090-19110" >&2; exit 2; }

kubectl --context "$CTX" -n "$NS" port-forward "svc/$SVC" "$LP:$PORT" >/tmp/triage-pf.log 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
for _ in $(seq 1 20); do
  curl -sf -o /dev/null "http://localhost:$LP/-/ready" && break
  sleep 1
done

READY=$(curl -sf "http://localhost:$LP/-/ready" 2>/dev/null || true)
if [ -z "$READY" ]; then
  echo "!! Prometheus did not answer on localhost:$LP. NOT reporting 'no alerts'."
  sed 's/^/   /' /tmp/triage-pf.log | head -5
  exit 2
fi
echo "   prometheus: $READY"

J=$(curl -s "http://localhost:$LP/api/v1/alerts")
TOTAL=$(printf '%s' "$J" | jq '[.data.alerts[] | select(.state=="firing")] | length')
echo "   firing: $TOTAL"
echo

# Which alertnames come from OUR PrometheusRules? Everything kube-prometheus-stack
# generates lives in a rule object named prometheus-stack-*; ours do not.
OURS=$(kubectl --context "$CTX" -n "$NS" get prometheusrule -o json 2>/dev/null \
      | jq -r '[.items[] | select((.metadata.name | startswith("prometheus-stack-")) | not)
                | .spec.groups[].rules[]? | select(.alert) | .alert] | unique | join("|")')
[ -n "$OURS" ] || OURS="__none__"
echo "   rules we own: $(printf '%s' "$OURS" | tr '|' '\n' | grep -c . ) alert names"
echo

echo "ALERT                                      COUNT OWN   SEV       OLDEST activeAt"
echo "---------------------------------------------------------------------------------"
printf '%s' "$J" | jq -r --arg ours "$OURS" '
  [.data.alerts[] | select(.state=="firing")]
  | group_by(.labels.alertname)
  | map({name: .[0].labels.alertname,
         n: length,
         sev: (.[0].labels.severity // "-"),
         oldest: (map(.activeAt) | sort | .[0])})
  | sort_by(.oldest)
  | .[]
  | ((.name | test("^(" + $ours + ")$")) as $own
     | "\(.name)|\(.n)|\(if $own then "ours" else "stack" end)|\(.sev)|\(.oldest[0:19])")
' | awk -F'|' '{ printf "%-42s %-5s %-5s %-9s %s\n", $1, $2, $3, $4, $5 }'

echo
echo "-- instances, oldest first --"
# Print the SUBJECT labels explicitly. `unique` collapsed namespace whenever it
# matched kube-state-metrics' own, and the job/deployment/daemonset name -- the
# only label that says WHICH thing failed -- was not printed at all, so
# "KubeJobFailed x11" named nothing.
printf '%s' "$J" | jq -r '
  [.data.alerts[] | select(.state=="firing")] | sort_by(.activeAt) | .[]
  | . as $a
  | ([ "ns=" + (.labels.exported_namespace // .labels.namespace // "-"),
       (if .labels.job_name then "job=" + .labels.job_name else empty end),
       (if .labels.deployment then "deploy=" + .labels.deployment else empty end),
       (if .labels.daemonset then "ds=" + .labels.daemonset else empty end),
       (if .labels.statefulset then "sts=" + .labels.statefulset else empty end),
       (if .labels.pod then "pod=" + .labels.pod else empty end),
       (if .labels.name then "name=" + .labels.name else empty end),
       (if .labels.container then "ctr=" + .labels.container else empty end),
       (if .labels.node then "node=" + .labels.node else empty end),
       (if .labels.poddisruptionbudget then "pdb=" + .labels.poddisruptionbudget else empty end)
     ] | join(" ")) as $subj
  | "\($a.activeAt[0:19])  \($a.labels.severity // "-")  \($a.labels.alertname)  \($subj)"'

echo
echo "-- alert instances whose labels carry the EXPORTER, not just the subject --"
echo "   (an exporter restart resets activeAt on every one of these, so their"
echo "    ages are unknown rather than recent -- 26 reset at the KSM restart)"
printf '%s' "$J" | jq -r '
  [.data.alerts[] | select(.state=="firing") | select(.labels.instance != null)]
  | group_by(.labels.instance)
  | map({instance: .[0].labels.instance, n: length,
         names: ([.[].labels.alertname] | unique | join(", "))})
  | .[] | "  \(.instance)  \(.n) alerts: \(.names)"'

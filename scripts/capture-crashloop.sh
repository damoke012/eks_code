#!/usr/bin/env bash
# Capture everything needed to diagnose a CrashLoopBackOff, in one read-only pass.
#
# READ-ONLY. get/describe/logs only. No kubectl run, no debug pod, no exec (CLAUDE.md rule 3).
#
# A crashlooping container is its own feedback loop: it fails every few minutes without help.
# The signal is in the PREVIOUS run, not the current one -- `kubectl logs` on a container
# that is in state.waiting returns nothing useful, which is why these get read as "no logs".
# `--previous` is the whole trick.
#
# Env VALUES are never printed, only names. A container spec routinely carries credentials
# in plain env, and this output gets pasted into chat.
#
#   scripts/capture-crashloop.sh op-dev risingwave-2 prometheus-server-596b5bc985-v45hb
#   scripts/capture-crashloop.sh op-prod risingwave <pod>       # any cluster
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLUSTER="${1:-}"; NS="${2:-}"; POD="${3:-}"
if [ -z "$CLUSTER" ] || [ -z "$NS" ] || [ -z "$POD" ]; then
  echo "usage: capture-crashloop.sh <op-dev|op-qa|op-prod> <namespace> <pod>" >&2
  exit 2
fi

. "$SCRIPT_DIR/lib-onprem-ctx.sh"
onprem_resolve_ctx "$CLUSTER" || exit 2
k() { kubectl --kubeconfig="$ONPREM_KC" --context="$ONPREM_CTX" "$@"; }

echo "== $CLUSTER / $NS / $POD   (node $ONPREM_NODE)"

# Which container is actually failing? A pod can read 2/2 Running while one container
# cycles: the failing one is in state.waiting and the healthy sibling masks it.
echo
echo "-- containers: state, restarts, last exit --"
k -n "$NS" get pod "$POD" -o json 2>/dev/null | python3 -c '
import datetime, json, sys
try: p = json.load(sys.stdin)
except Exception: print("   could not read the pod as JSON"); raise SystemExit(0)
now = datetime.datetime.now(datetime.timezone.utc)
cs = (p.get("status") or {}).get("containerStatuses") or []
if not cs: print("   no containerStatuses")
for c in cs:
    st = c.get("state") or {}
    where = "running" if "running" in st else ("waiting" if "waiting" in st else "terminated")
    why = (st.get("waiting") or {}).get("reason", "") or (st.get("terminated") or {}).get("reason", "")
    line = "   %-28s %-11s %-22s restarts=%d" % (c.get("name"), where, why, c.get("restartCount", 0))
    last = (c.get("lastState") or {}).get("terminated") or {}
    if last:
        fin = last.get("finishedAt", "")
        ago = ""
        if fin:
            t = datetime.datetime.fromisoformat(fin.replace("Z", "+00:00"))
            ago = " (%d min ago)" % ((now - t).total_seconds() / 60)
        line += "\n      last exit: code=%s reason=%s%s" % (
            last.get("exitCode"), last.get("reason"), ago)
        if last.get("message"): line += "\n      message: %s" % last["message"][:300]
    print(line)
    # NAMES only. Values are not printed: this output gets pasted into chat.
    print("      env: " + ", ".join(
        e.get("name","?") for cn in ((p.get("spec") or {}).get("containers") or [])
        if cn.get("name") == c.get("name") for e in (cn.get("env") or [])) or "      env: (none)")
'

# The actual failure text. --previous, because the current container is not running.
for cname in $(k -n "$NS" get pod "$POD" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null); do
  echo
  echo "-- logs --previous: $cname (last 40 lines) --"
  out=$(k -n "$NS" logs "$POD" -c "$cname" --previous --tail=40 2>&1)
  if [ -z "$out" ]; then
    echo "   (empty)"
  else
    printf '%s\n' "$out" | sed 's/^/   /'
  fi
done

echo
echo "-- events for this pod (most recent last) --"
k -n "$NS" get events --field-selector "involvedObject.name=$POD" \
  --sort-by=.lastTimestamp 2>/dev/null | tail -15 | sed 's/^/   /'

echo
echo "-- probes and resources (an OOMKill or a failing probe is not an app bug) --"
k -n "$NS" get pod "$POD" -o json 2>/dev/null | python3 -c '
import json, sys
try: p = json.load(sys.stdin)
except Exception: raise SystemExit(0)
for c in ((p.get("spec") or {}).get("containers") or []):
    print("   %s" % c.get("name"))
    print("      resources: %s" % json.dumps(c.get("resources") or {}))
    for probe in ("livenessProbe", "readinessProbe", "startupProbe"):
        if c.get(probe): print("      %s: %s" % (probe, json.dumps(c[probe])))
'

echo
echo "Next: exitCode 137 = OOMKilled or SIGKILL (check resources.limits.memory)."
echo "      exitCode 1/2 with app text = read the log above."
echo "      Empty --previous logs + Killing events = a probe is restarting it, not a crash."

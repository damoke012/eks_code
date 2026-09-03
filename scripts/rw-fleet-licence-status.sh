#!/usr/bin/env bash
# Are the RisingWave pods healthy, and is the console licence real, on EVERY cluster?
#
# READ-ONLY. get only. Written 2026-09-03 after the licence was pushed to "all environments
# through automation" — a claim about a fleet needs the sweep, not the one cluster that
# prompted it (CLAUDE.md rule 5).
#
# Three things this checks that the obvious version does not:
#
#   * RESTARTS, not just STATUS. A crashlooping pod shows "Running" between backoffs.
#     On 2026-09-03 risingwave-console on op-prod was reported 2/2 Running with 532
#     restarts, and rw-prod-status gate 3 called that healthy.
#   * The licence VALUE and its EXPIRY, not SecretSynced. A green ExternalSecret proves the
#     sync ran, not that the content works, and a valid JWT is only valid until a date. The
#     current licence expires 2026-10-15.
#   * UNREACHABLE is reported as UNKNOWN, never as absence. A cluster behind a dropped VPN
#     must not read as "RisingWave is not deployed there" (see transport-failure-not-a-verdict).
#
# dev carries BOTH `risingwave` and `risingwave-2`; risingwave-2 is dev-only and is never
# promoted. QA and prod are always `risingwave`.
#
#   bash scripts/rw-fleet-licence-status.sh                 # all three
#   bash scripts/rw-fleet-licence-status.sh op-qa op-prod   # a subset
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACES="risingwave risingwave-2"
RESTART_LIMIT=10

CLUSTERS="$*"; [ -n "$CLUSTERS" ] || CLUSTERS="op-dev op-qa op-prod"

bad=0; unknown=0; good=0
ERRF=$(mktemp); trap 'rm -f "$ERRF"' EXIT

# Overridable ONLY so rw-fleet-licence-status.test.sh can replay recorded output. When unset,
# the cluster is resolved by ENDPOINT and by live node name, never by a filename.
FAKE="${RW_FLEET_KUBECTL:-}"
if [ -z "$FAKE" ]; then
  # shellcheck source=lib-onprem-ctx.sh
  . "$SCRIPT_DIR/lib-onprem-ctx.sh"
fi

for cluster in $CLUSTERS; do
  printf '\n=== %s\n' "$cluster"

  if [ -n "$FAKE" ]; then
    kc() { "$FAKE" "$CLUSTER_NOW" -- "$@"; }
    CLUSTER_NOW="$cluster"
  else
    # NOT `onprem_resolve_ctx ... | sed` and NOT `$(onprem_resolve_ctx ...)`. Both run the
    # function in a SUBSHELL, so the ONPREM_KC/ONPREM_CTX it exports never reach this shell,
    # and a pipeline's exit status is sed's, not the resolver's. The first version of this
    # script did exactly that: it printed the candidate line, then died on an unbound
    # ONPREM_KC under `set -u` with no error. Redirecting stderr to a file is not a subshell.
    ONPREM_KC=""; ONPREM_CTX=""
    onprem_resolve_ctx "$cluster" 2>"$ERRF"; rc=$?
    [ -s "$ERRF" ] && sed 's/^/  /' "$ERRF"
    if [ "$rc" -ne 0 ] || [ -z "$ONPREM_KC" ] || [ -z "$ONPREM_CTX" ]; then
      printf '  UNKNOWN   cannot reach %s — NOT a statement about whether RisingWave is there\n' "$cluster"
      unknown=$((unknown+1)); continue
    fi
    kc() { kubectl --kubeconfig="$ONPREM_KC" --context="$ONPREM_CTX" "$@"; }
  fi

  found_ns=0
  for ns in $NAMESPACES; do
    kc get ns "$ns" >/dev/null 2>&1 || continue
    found_ns=$((found_ns+1))

    pods=$(kc -n "$ns" get pods -o json 2>/dev/null)
    if [ -z "$pods" ]; then
      printf '  UNKNOWN   %s/%s: could not read pods\n' "$cluster" "$ns"
      unknown=$((unknown+1)); continue
    fi

    # Parse JSON, not columns. rw-prod-status gate 5 keyed on awk $NF and had no passing
    # branch for weeks because the last column was not the one it assumed.
    verdict=$(printf '%s' "$pods" | RESTART_LIMIT="$RESTART_LIMIT" python3 -c '
import datetime, json, os, sys
lim = int(os.environ["RESTART_LIMIT"])
items = json.load(sys.stdin).get("items", [])
now = datetime.datetime.now(datetime.timezone.utc)
notready, churn, healed = [], [], []
for p in items:
    name  = p["metadata"]["name"]
    phase = p.get("status", {}).get("phase", "?")
    cs    = p.get("status", {}).get("containerStatuses") or []
    r     = max([c.get("restartCount", 0) for c in cs], default=0)
    # A cumulative restart count never goes down, so "532 restarts" alone cannot tell a pod
    # that is crashlooping RIGHT NOW from one that settled hours ago. How long the current
    # container instance has been up is the discriminator. Without it this check would shout
    # CRASHLOOPING at a recovered pod forever, and get ignored -- the way any guard that
    # cries wolf gets switched off.
    up = None
    for c in cs:
        st = (c.get("state") or {}).get("running", {}).get("startedAt")
        if st:
            t = datetime.datetime.fromisoformat(st.replace("Z", "+00:00"))
            mins = (now - t).total_seconds() / 60
            up = mins if up is None else min(up, mins)
    if phase not in ("Running", "Succeeded"):
        notready.append("%s(%s)" % (name, phase))
    elif r > lim:
        if up is not None and up >= 60:
            healed.append("%s(%d restarts, stable %dh)" % (name, r, up // 60))
        else:
            age = "just now" if up is None else "%dm ago" % up
            churn.append("%s(%d restarts, last %s)" % (name, r, age))
print(json.dumps({"total": len(items), "notready": notready,
                  "churn": churn, "healed": healed}))')

    tot=$(printf '%s' "$verdict"      | python3 -c 'import json,sys;print(json.load(sys.stdin)["total"])')
    nr=$(printf '%s' "$verdict"       | python3 -c 'import json,sys;print(" ".join(json.load(sys.stdin)["notready"]))')
    ch=$(printf '%s' "$verdict"       | python3 -c 'import json,sys;print(" ".join(json.load(sys.stdin)["churn"]))')
    hl=$(printf '%s' "$verdict"       | python3 -c 'import json,sys;print(" ".join(json.load(sys.stdin)["healed"]))')

    if [ "$tot" -eq 0 ]; then
      printf '  UNKNOWN   %s: namespace exists but has no pods\n' "$ns"; unknown=$((unknown+1))
    elif [ -n "$nr" ]; then
      printf '  BAD       %s: %s\n' "$ns" "$nr"; bad=$((bad+1))
    elif [ -n "$ch" ]; then
      printf '  BAD       %s: %d/%d Running but CRASHLOOPING: %s\n' "$ns" "$tot" "$tot" "$ch"; bad=$((bad+1))
    elif [ -n "$hl" ]; then
      printf '  WARN      %s: %d/%d Running, recovered but scarred: %s\n' "$ns" "$tot" "$tot" "$hl"; good=$((good+1))
    else
      printf '  OK        %s: %d/%d Running, none restarting\n' "$ns" "$tot" "$tot"; good=$((good+1))
    fi

    # ── the licence itself ────────────────────────────────────────────────────
    lsec=$(kc -n "$ns" get externalsecret rw-license-key -o jsonpath='{.spec.target.name}' 2>/dev/null)
    [ -n "$lsec" ] || lsec=rw-license-key
    lic=$(kc -n "$ns" get secret "$lsec" -o json 2>/dev/null | python3 -c '
import base64, json, sys
try: d = json.load(sys.stdin).get("data", {})
except Exception: sys.exit(0)
for v in d.values():
    try: t = base64.b64decode(v).decode()
    except Exception: continue
    if t.count(".") == 2 and t.startswith("eyJ"): print(t); break' 2>/dev/null)

    if [ -z "$lic" ]; then
      # Distinguish "no licence object here" from "there is one and it is junk".
      if kc -n "$ns" get secret "$lsec" >/dev/null 2>&1; then
        printf '  BAD       %s: secret %s holds no compact JWT (placeholder?)\n' "$ns" "$lsec"; bad=$((bad+1))
      else
        printf '  n/a       %s: no licence secret %s — this namespace may not run the console\n' "$ns" "$lsec"
      fi
    else
      exp=$(printf '%s' "$lic" | python3 -c '
import base64, json, sys
t = sys.stdin.read().strip().split(".")[1]; t += "=" * (-len(t) % 4)
print(json.loads(base64.urlsafe_b64decode(t)).get("exp", 0))' 2>/dev/null)
      now=$(date +%s)
      if [ -n "$exp" ] && [ "$exp" -gt "$now" ] 2>/dev/null; then
        days=$(( (exp - now) / 86400 ))
        when=$(date -u -d "@$exp" +%Y-%m-%d)
        if [ "$days" -lt 30 ]; then
          printf '  BAD       %s: licence valid but EXPIRES IN %d DAYS (%s) — renew\n' "$ns" "$days" "$when"; bad=$((bad+1))
        else
          printf '  OK        %s: licence is a real JWT, expires %s (%d days)\n' "$ns" "$when" "$days"; good=$((good+1))
        fi
      else
        printf '  BAD       %s: licence JWT is EXPIRED or unparseable\n' "$ns"; bad=$((bad+1))
      fi
    fi
  done

  [ "$found_ns" -eq 0 ] && {
    printf '  UNKNOWN   no RisingWave namespace on %s (looked for: %s)\n' "$cluster" "$NAMESPACES"
    unknown=$((unknown+1)); }
done

printf '\n=== FLEET  %d ok, %d bad, %d unknown\n' "$good" "$bad" "$unknown"
if [ "$bad" -eq 0 ] && [ "$unknown" -eq 0 ]; then
  echo "RisingWave is healthy on every cluster checked, with a valid licence."
else
  echo "NOT clean — an UNKNOWN is not a pass; it is a cluster nobody looked at."
fi
# Exit codes are part of the contract: 1 = something is wrong, 2 = something was not
# looked at. An all-UNKNOWN run must NOT exit 0 -- "I could not check" is not "it is fine",
# and a caller treating it as success is how a fleet gets reported healthy unseen.
[ "$bad" -eq 0 ]     || exit 1
[ "$unknown" -eq 0 ] || exit 2
exit 0

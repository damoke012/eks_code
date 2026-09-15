#!/usr/bin/env bash
# Report Flux Kustomizations that are NOT Ready, with the condition message.
#
# Written 2026-09-15 after iaac-risingwave-onprem#36: the QA `risingwave-onprem`
# Kustomization failed its server-side-apply dry-run on every reconcile for ~4 hours
# ("spec.strategy.rollingUpdate: Forbidden ...") and froze every resource it owned.
# Nothing reported it -- op-usxpress-qa has NO Alertmanager, so no PrometheusRule could
# have reached anyone either. This is the interim detector until ALERTS-TO-BUILD P1 lands.
#
# Distinct from scripts/flux-revision-drift.sh: that one catches a STALE revision
# (ALERTS-TO-BUILD C4). This catches a reconcile that is actively ERRORING (C6), where
# lastAppliedRevision sits at the last good sha and drift alone looks normal.
#
# The condition MESSAGE is the point: `dry-run failed (Invalid)` names the resource and
# the exact field, which is the whole diagnosis.
#
# Usage:
#   bash scripts/flux-kustomization-health.sh --cluster op-dev [--cluster op-qa ...]
#   bash scripts/flux-kustomization-health.sh --kubeconfig /path/to/kubeconfig
#
# Exit: 0 all Ready | 3 at least one not Ready | 7 at least one cluster not assessable
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KCS=()     # resolved kubeconfig paths
CTXS=()    # matching --context, empty string when unpinned
LABELS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --cluster)
      # Resolve BY ENDPOINT, never by filename: a config file can claim anything.
      # shellcheck source=/dev/null
      source "$HERE/lib-onprem-ctx.sh"
      if onprem_resolve_ctx "$2"; then
        KCS+=("$ONPREM_KC"); CTXS+=("$ONPREM_CTX"); LABELS+=("$2")
      else
        echo "CANNOT RESOLVE $2 -- this says nothing about its Kustomizations."
        KCS+=(""); CTXS+=(""); LABELS+=("$2")
      fi
      shift 2 ;;
    --kubeconfig)
      KCS+=("$2"); CTXS+=(""); LABELS+=("$(basename "$2")"); shift 2 ;;
    *) echo "usage: $0 --cluster op-dev|op-qa|op-prod [...] | --kubeconfig <path>" >&2; exit 2 ;;
  esac
done

[ ${#KCS[@]} -ge 1 ] || { echo "usage: $0 --cluster op-dev|op-qa|op-prod [...]" >&2; exit 2; }

rc=0
unreachable=0

for idx in "${!KCS[@]}"; do
  KC="${KCS[$idx]}"; CTX="${CTXS[$idx]}"; CLUSTER="${LABELS[$idx]}"

  if [ -z "$KC" ]; then unreachable=1; continue; fi
  if [ ! -r "$KC" ]; then
    echo "CANNOT READ kubeconfig $KC -- this says nothing about $CLUSTER."
    unreachable=1; continue
  fi

  PIN=(--kubeconfig "$KC")
  [ -n "$CTX" ] && PIN+=(--context "$CTX")

  if ! raw=$(kubectl "${PIN[@]}" get kustomizations.kustomize.toolkit.fluxcd.io \
               -A -o json 2>&1); then
    case "$raw" in
      *Unauthorized*|*"must be logged in"*|*"asked for the credentials"*)
        echo "CANNOT AUTHENTICATE to $CLUSTER -- this says nothing about its Kustomizations." ;;
      *"connection refused"*|*"no such host"*|*timeout*|*"i/o timeout"*|*"context deadline"*)
        echo "CANNOT REACH $CLUSTER -- this says nothing about its Kustomizations." ;;
      *"server doesn't have a resource type"*|*NotFound*)
        echo "$CLUSTER has no Flux Kustomization CRD -- not a Flux-managed cluster?" ;;
      *)
        echo "UNEXPECTED failure listing Kustomizations on $CLUSTER:" ;;
    esac
    printf '%s\n' "$raw" | head -2
    unreachable=1; continue
  fi

  if ! total=$(printf '%s' "$raw" | python3 -c \
       'import json,sys; print(len(json.load(sys.stdin)["items"]))' 2>/dev/null); then
    echo "CANNOT PARSE the Kustomization list from $CLUSTER -- this says nothing about its health."
    unreachable=1; continue
  fi
  if [ "$total" -eq 0 ]; then
    # Zero rows is not health. Say so rather than printing a clean bill.
    echo "$CLUSTER: NO Kustomizations returned -- verify the CRD and your RBAC before reading this as healthy."
    unreachable=1; continue
  fi

  bad=$(printf '%s' "$raw" | python3 -c '
import json, sys
items = json.load(sys.stdin)["items"]
for k in items:
    st = k.get("status", {})
    conds = {c["type"]: c for c in st.get("conditions", [])}
    ready = conds.get("Ready")
    ns   = k["metadata"]["namespace"]
    name = k["metadata"]["name"]
    if k.get("spec", {}).get("suspend"):
        print("SUSPENDED\t%s/%s\treconciliation is off -- intentional?" % (ns, name))
        continue
    if ready is None:
        print("NO-STATUS\t%s/%s\tnever reconciled" % (ns, name))
        continue
    if ready.get("status") != "True":
        msg = " ".join(ready.get("message", "").split())[:300]
        print("NOT-READY\t%s/%s\t[%s] %s" % (ns, name, ready.get("reason", "?"), msg))
')
  # A parser that dies must never read as a clean bill of health -- on 2026-09-15 the
  # first version of this script did exactly that, printing "all 4 Kustomizations Ready"
  # from a SyntaxError. Fail closed.
  if [ $? -ne 0 ]; then
    echo "CANNOT PARSE the Kustomization list from $CLUSTER -- this says nothing about its health."
    unreachable=1; continue
  fi

  if [ -n "$bad" ]; then
    echo "== $CLUSTER: $(printf '%s\n' "$bad" | grep -c .) of $total Kustomizations need attention"
    printf '%s\n' "$bad" | sed 's/^/   /'
    printf '%s\n' "$bad" | grep -q '^NOT-READY' && rc=3
  else
    echo "== $CLUSTER: all $total Kustomizations Ready"
  fi
done

[ "$unreachable" -eq 1 ] && exit 7
exit $rc

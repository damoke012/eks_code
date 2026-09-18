#!/usr/bin/env bash
# Does each HelmRelease's Ready condition agree with its Helm history?
#
# On op-usxpress-qa, 2026-09-18: `grafana/grafana` had been Stalled/RetriesExceeded
# since 2026-07-14 -- 66 days with no install attempt -- while the Grafana pod ran
# 3/3, 0 restarts, for 72 days. Nothing committed under infrastructure/grafana/ had
# reached the cluster in over two months, and no status field said so.
#
# TWO failure shapes, opposite severities, and Ready cannot tell them apart:
#
#   release BROKEN + workload UP    -> GitOps is silently a no-op. Nobody notices,
#                                      because the thing looks fine. This is the
#                                      dangerous one.
#   release BROKEN + workload DOWN  -> an outage. Someone notices within the hour.
#
# A devops agent reported QA's as HIGH "Grafana HelmRelease failed" and inferred
# Grafana was unavailable. The observation was right and the inference was wrong,
# which aimed the remediation at a deployment that was not failing. So this script
# prints the workload state beside the release state and refuses to collapse them.
#
# It also flags the two spec defaults that produced the stall, because they are
# silent and identical on every unpatched HelmRelease:
#   * no .spec.timeout        -> Helm waits 5m for readiness, then records `failed`
#                                on an install that was merely slow.
#   * install.remediation without remediateLastFailure (defaults FALSE for install,
#                                TRUE for upgrade) -> every retry attempts an UPGRADE
#                                of a release whose only version is a failed install,
#                                which Helm refuses. Retries exhaust against an error
#                                they can never clear.
#
# READ ONLY. Nothing here writes, patches, applies or deletes.
#
#   scripts/check-helmrelease-truth.sh --context admin@op-usxpress-qa
#   scripts/check-helmrelease-truth.sh --context op-usxpress-qa-sso --namespace grafana
#
# Exit 0 = every release agrees with its history. 1 = at least one does not.
#          2 = could not be checked. An UNKNOWN is never reported as a pass.
set -uo pipefail

CTX=""; KCFG=""; NS_FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --context)    CTX="$2";       shift 2 ;;
    --kubeconfig) KCFG="$2";      shift 2 ;;
    --namespace)  NS_FILTER="$2"; shift 2 ;;
    -h|--help)    sed -n '2,36p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$CTX" ] || { echo "usage: $0 --context <ctx> [--kubeconfig PATH] [--namespace NS]" >&2; exit 2; }

k() { kubectl ${KCFG:+--kubeconfig="$KCFG"} --context "$CTX" "$@"; }
command -v jq >/dev/null || { echo "!! jq not installed" >&2; exit 2; }

US=$(printf '\037')
FAIL=0; UNKNOWN=0; ADVISORY=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
unkn() { printf '  ????  %s\n' "$1"; UNKNOWN=$((UNKNOWN+1)); }
advi() { printf '  ADVS  %s\n' "$1"; ADVISORY=$((ADVISORY+1)); }
note() { printf '        %s\n' "$1"; }

# A transport failure is not a finding about the cluster -- abort rather than
# reporting "no HelmReleases", which reads like a clean result.
if ! SERVER=$(k config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null) \
   || ! k version -o json >/dev/null 2>&1; then
  echo "!! cannot reach the cluster on context '$CTX' -- nothing below was checked" >&2
  exit 2
fi

echo "=== HelmRelease truth: $CTX ==="
echo "    apiserver $SERVER"
echo

if [ -n "$NS_FILTER" ]; then
  HR=$(k get helmreleases.helm.toolkit.fluxcd.io -n "$NS_FILTER" -o json 2>/dev/null)
else
  HR=$(k get helmreleases.helm.toolkit.fluxcd.io -A -o json 2>/dev/null)
fi
if [ -z "$HR" ]; then
  unkn "could not list HelmReleases (CRD absent, or no permission)"
  echo; echo "FAILED: 0. UNKNOWN: 1."
  exit 2
fi

COUNT=$(echo "$HR" | jq '.items | length')
if [ "$COUNT" -eq 0 ]; then
  unkn "zero HelmReleases returned -- verify the selector before concluding none exist"
  echo; echo "FAILED: 0. UNKNOWN: 1."
  exit 2
fi
echo "$COUNT HelmRelease(s)"
echo

NOW=$(date -u +%s)

while IFS="$US" read -r NS NAME READY STALLED HIST ACTION DUR MSG TIMEOUT ITIMEOUT RLF VER LAST; do
  [ -n "$NAME" ] || continue
  ID="$NS/$NAME"

  # --- the workload, measured BEFORE the verdict, so severity is not guessed ---
  # Helm stamps app.kubernetes.io/instance on chart resources. Where a chart does not,
  # fall back to the namespace and SAY SO -- a namespace-wide count is not a statement
  # about this release.
  PODS=$(k get pods -n "$NS" -l "app.kubernetes.io/instance=$NAME" -o json 2>/dev/null)
  SCOPE="release"
  if [ -z "$PODS" ] || [ "$(echo "$PODS" | jq '.items | length')" -eq 0 ]; then
    PODS=$(k get pods -n "$NS" -o json 2>/dev/null); SCOPE="namespace"
  fi
  if [ -z "$PODS" ]; then
    RUN="?"; TOT="?"
  else
    TOT=$(echo "$PODS" | jq '.items | length')
    RUN=$(echo "$PODS" | jq '[.items[] | select(.status.phase=="Running")] | length')
  fi

  if [ "$HIST" = "deployed" ] && [ "$READY" = "True" ]; then
    pass "$ID  history=deployed  pods ${RUN}/${TOT} ($SCOPE)"
  else
    fail "$ID  Ready=$READY  history=${HIST:--}  pods ${RUN}/${TOT} ($SCOPE)"
    [ "$MSG" != "-" ] && note "$MSG"
    if [ "$STALLED" = "True" ]; then
      note "Stalled=True -- Flux has GIVEN UP. It retries per generation, so only a"
      note "  spec change (new generation) restarts it. Waiting does nothing."
    fi
    if [ -n "$LAST" ] && [ "$LAST" != "-" ]; then
      if LSEC=$(date -u -d "$LAST" +%s 2>/dev/null); then
        note "last reconcile attempt $(( (NOW - LSEC) / 86400 ))d ago ($LAST)"
      fi
    fi
    if [ "$RUN" != "?" ] && [ "$RUN" -gt 0 ]; then
      note "the workload is RUNNING. This is not an outage -- it is GitOps silently"
      note "  doing nothing. Every commit to this release's path is a no-op until fixed."
    fi
    [ "$ACTION" != "-" ] && note "last attempted action: $ACTION${DUR:+, took $DUR}"
  fi

  # --- the two silent defaults, reported whatever the verdict ---
  if [ "$TIMEOUT" = "-" ] && [ "$ITIMEOUT" = "-" ]; then
    advi "$ID  no .spec.timeout -- Helm gives readiness 5m, then records a slow install as failed"
  fi
  if [ "$RLF" = "false-unset" ]; then
    advi "$ID  install.remediation has no remediateLastFailure (defaults FALSE for install,"
    note "  TRUE for upgrade). Retries will try to UPGRADE a failed install and cannot succeed."
  fi
  case "$VER" in
    *x*|*"*"*|">"*|"^"*|"~"*)
      advi "$ID  chart version '$VER' floats -- the next reconcile may resolve a different chart" ;;
  esac
done < <(echo "$HR" | jq -r '.items[] | [
    .metadata.namespace, .metadata.name,
    ((.status.conditions // [] | map(select(.type=="Ready"))   | .[0].status)  // "-"),
    ((.status.conditions // [] | map(select(.type=="Stalled")) | .[0].status)  // "-"),
    ((.status.history // [] | .[0].status) // "-"),
    (.status.lastAttemptedReleaseAction // "-"),
    (.status.lastAttemptedReleaseActionDuration // ""),
    ((.status.conditions // [] | map(select(.type=="Ready"))   | .[0].message) // "-"),
    (.spec.timeout // "-"),
    (.spec.install.timeout // "-"),
    (if (.spec.install.remediation // null) == null then "no-remediation"
     elif (.spec.install.remediation.remediateLastFailure // null) == null then "false-unset"
     else (.spec.install.remediation.remediateLastFailure | tostring) end),
    (.spec.chart.spec.version // "-"),
    (.status.lastHandledReconcileAt // "-")
  ] | join("")')

echo
echo "=== $CTX ==="
echo "FAILED: $FAIL. UNKNOWN: $UNKNOWN. ADVISORY: $ADVISORY."
echo
echo "A HelmRelease whose history is not 'deployed' cannot receive changes, whether or"
echo "not its pods are healthy. Read the history, not the Ready condition."
[ "$FAIL" -gt 0 ] && exit 1
[ "$UNKNOWN" -gt 0 ] && exit 2
exit 0

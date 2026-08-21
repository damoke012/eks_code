#!/usr/bin/env bash
# Is the on-prem platform baseline ACTUALLY in the state we say it is?
#
# Written because INFRA-1640 and INFRA-1641 were both closed after fixing ONE
# cluster of three: neither ticket named a cluster, the branch that was verified
# was op-qa, and op-dev and op-prod carried the old config for weeks with every
# status field green. Point this at each cluster instead of trusting that a
# merged PR reached it.
#
# Every assertion is about EFFECT, not about YAML. A CronJob with the right
# schedule that has never completed is a failure here, not a pass.
#
# READ ONLY. Nothing here writes, patches, applies or deletes.
#
#   scripts/check-onprem-platform-state.sh --context op-usxpress-qa-sso
#   scripts/check-onprem-platform-state.sh --context admin@op-usxpress-dev
#   scripts/check-onprem-platform-state.sh --context admin@op-usxpress-prod \
#       --kubeconfig ~/.kube/op-usxpress-prod-breakglass.yaml
#
# Exit 0 = every check passed. 1 = at least one FAILED.
#          2 = at least one could not be checked (UNKNOWN) and none failed.
# An UNKNOWN is never reported as a pass.
set -uo pipefail

CTX=""; KCFG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --context)    CTX="$2";  shift 2 ;;
    --kubeconfig) KCFG="$2"; shift 2 ;;
    -h|--help)    sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$CTX" ] || { echo "usage: $0 --context <ctx> [--kubeconfig PATH]" >&2; exit 2; }

k() { kubectl ${KCFG:+--kubeconfig="$KCFG"} --context "$CTX" "$@"; }
command -v jq >/dev/null || { echo "!! jq not installed" >&2; exit 2; }

US=$'\037'
FAIL=0; UNKNOWN=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
unkn() { printf '  \033[33m????\033[0m  %s\n' "$1"; UNKNOWN=$((UNKNOWN+1)); }
note() { printf '        %s\n' "$1"; }

if ! SERVER=$(k config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null) \
   || ! k version -o json >/dev/null 2>&1; then
  echo "!! cannot reach the cluster on context '$CTX' — nothing below was checked" >&2
  exit 2
fi

echo "=== on-prem platform baseline: $CTX ==="
echo "    apiserver $SERVER"
echo

# ---------------------------------------------------------------- Flux --------
echo "Flux Kustomizations"
KS=$(k get kustomizations.kustomize.toolkit.fluxcd.io -A -o json 2>/dev/null)
if [ -z "$KS" ]; then
  unkn "could not list Kustomizations"
else
  while IFS="$US" read -r NS NAME READY MSG; do
    [ -n "$NAME" ] || continue
    if [ "$READY" = "True" ]; then pass "$NS/$NAME"
    else fail "$NS/$NAME  Ready=$READY"; note "$MSG"; fi
  done < <(echo "$KS" | jq -r '.items[] | [
      .metadata.namespace, .metadata.name,
      ((.status.conditions // [] | map(select(.type=="Ready")) | .[0].status)  // "-"),
      ((.status.conditions // [] | map(select(.type=="Ready")) | .[0].message) // "-")
    ] | join("\u001f")')
fi
echo

# -------------------------------------------------------------- Kyverno -------
# INFRA-1640 / INFRA-1641. Audit logs a violation and admits the pod; Enforce
# rejects it. allowExistingViolations is printed because it changes what Enforce
# actually promises — with it true, only NEW admissions are gated, and saying
# "these are now rejected" without it is an overstatement.
echo "Kyverno image policies (INFRA-1640 / INFRA-1641)"
for POL in require-approved-registry require-image-digest; do
  J=$(k get clusterpolicy "$POL" -o json 2>/dev/null)
  if [ -z "$J" ]; then unkn "$POL — not present, or could not be read"; continue; fi
  ACTION=$(echo "$J" | jq -r '.spec.validationFailureAction // "-"')
  # NOT `.[0] // "unset"` — jq's // treats `false` as empty, so the STRONGER
  # setting would have been reported as unset. Tested; it did.
  AEV=$(echo    "$J" | jq -r '[.spec.rules[]?.validate.allowExistingViolations]
                              | map(select(. != null))
                              | if length > 0 then (.[0] | tostring) else "unset" end')
  READY=$(echo  "$J" | jq -r '(.status.conditions // [] | map(select(.type=="Ready")) | .[0].status) // "-"')
  if [ "$ACTION" = "Enforce" ] && [ "$READY" = "True" ]; then
    pass "$POL  Enforce, Ready"
  elif [ "$ACTION" = "Enforce" ]; then
    fail "$POL  Enforce but Ready=$READY — a policy that is not Ready gates nothing"
  else
    fail "$POL  validationFailureAction=$ACTION (want Enforce)"
  fi
  if [ "$AEV" = "true" ]; then note "allowExistingViolations=true  <- NEW admissions only"
  else note "allowExistingViolations=$AEV"; fi
done
echo

# -------------------------------------------------- ECR credential sync -------
echo "ECR credential sync (namespace ecr-credentials)"
CJ=$(k -n ecr-credentials get cronjob ecr-credentials-sync -o json 2>/dev/null)
if [ -z "$CJ" ]; then
  unkn "cronjob ecr-credentials/ecr-credentials-sync — not present, or could not be read"
else
  SCHED=$(echo  "$CJ" | jq -r '.spec.schedule')
  CONC=$(echo   "$CJ" | jq -r '.spec.concurrencyPolicy // "Allow"')
  SUSP=$(echo   "$CJ" | jq -r '.spec.suspend // false')
  LASTOK=$(echo "$CJ" | jq -r '.status.lastSuccessfulTime // ""')
  [ "$SCHED" = "0 */6 * * *" ] && pass "schedule $SCHED" || fail "schedule $SCHED (want 0 */6 * * *)"
  [ "$CONC"  = "Forbid" ]      && pass "concurrencyPolicy Forbid" || fail "concurrencyPolicy $CONC (want Forbid)"
  [ "$SUSP"  = "false" ]       && pass "not suspended" || fail "SUSPENDED — it is not running at all"

  # A schedule is a claim. lastSuccessfulTime is the evidence.
  if [ -z "$LASTOK" ]; then
    fail "never completed successfully — .status.lastSuccessfulTime is empty"
  else
    AGE=$(( $(date -u +%s) - $(date -u -d "$LASTOK" +%s) ))
    if [ "$AGE" -le 27000 ]; then pass "last success $LASTOK ($((AGE/60)) min ago)"
    else fail "last success $LASTOK ($((AGE/3600))h ago) — a 6-hourly job is overdue"; fi
  fi
fi

JOB=$(k -n ecr-credentials get job ecr-credentials-sync-init -o json 2>/dev/null)
if [ -z "$JOB" ]; then
  note "init Job absent — expected once its TTL has expired, not a failure"
else
  TTL=$(echo "$JOB" | jq -r '.spec.ttlSecondsAfterFinished // "unset"')
  SUC=$(echo "$JOB" | jq -r '.status.succeeded // 0')
  [ "$TTL" = "86400" ] && pass "init Job ttlSecondsAfterFinished=86400" \
                       || fail "init Job ttlSecondsAfterFinished=$TTL (want 86400)"
  [ "$SUC" -ge 1 ] && pass "init Job completed" \
                   || fail "init Job has not completed — a failed Job is immutable and pins the Kustomization"
fi

# The point of the CronJob is the secret. Count where it landed. The excluded
# four are the ones sync.sh itself skips — keep the two lists identical.
NSALL=$(k get ns -o json 2>/dev/null | jq -r '.items[].metadata.name
          | select(. != "kube-system" and . != "kube-public"
                   and . != "kube-node-lease" and . != "flux-system")' | sort)
# NOT `get secret ecr-pull-secret -A`: kubectl REFUSES to fetch a resource by
# name across all namespaces ("a resource cannot be retrieved by name across all
# namespaces"). With stderr discarded that error became an empty list, and the
# first run of this script reported the secret missing from 31 of 31 namespaces
# 20 minutes after the CronJob had succeeded. A field selector is the query that
# actually works, and the exit status is checked rather than assumed.
SECJSON=$(k get secret -A --field-selector "metadata.name=ecr-pull-secret" -o json 2>&1)
SECRC=$?
if [ "$SECRC" -ne 0 ]; then
  unkn "could not query ecr-pull-secret — $(printf '%s' "$SECJSON" | head -1)"
  NSALL=""
else
  NSSEC=$(printf '%s' "$SECJSON" | jq -r '.items[].metadata.namespace' | sort)
fi
if [ -z "$NSALL" ]; then
  [ "$SECRC" -eq 0 ] && unkn "could not enumerate namespaces — pull-secret coverage not checked"
else
  TOTAL=$(printf '%s\n' "$NSALL" | grep -c .)
  HAVE=$(printf  '%s\n' "$NSSEC" | grep -c . )
  MISSING=$(comm -23 <(printf '%s\n' "$NSALL") <(printf '%s\n' "$NSSEC"))
  if [ -z "$MISSING" ]; then
    pass "ecr-pull-secret present in all $TOTAL eligible namespaces"
  else
    fail "ecr-pull-secret missing from $(printf '%s\n' "$MISSING" | grep -c .) of $TOTAL namespaces (have $HAVE)"
    printf '%s\n' "$MISSING" | sed 's/^/          - /'
    note "a namespace created since the last run is expected here for up to 6h"
  fi
fi
echo

# -------------------------------------------------------------- verdict -------
echo "=== $CTX ==="
if [ "$FAIL" -gt 0 ]; then
  echo "FAILED: $FAIL check(s). UNKNOWN: $UNKNOWN."; exit 1
elif [ "$UNKNOWN" -gt 0 ]; then
  echo "No failures, but $UNKNOWN check(s) could NOT be made. This is not a pass."; exit 2
fi
echo "All checks passed."

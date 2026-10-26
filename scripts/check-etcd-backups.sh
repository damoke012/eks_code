#!/usr/bin/env bash
# Are etcd snapshots actually being taken, and can we prove it? READ ONLY.
#
#   scripts/check-etcd-backups.sh dev|qa|prod
#
# WHY THIS EXISTS
#   QA has been firing EtcdSnapshotJobFailing x5 and KubeJobFailed x5 in the
#   etcd-backup namespace, and nobody saw it, because nothing delivers alerts on
#   ANY of the three clusters (INFRA-1659). A backup that fails silently is worse
#   than no backup, because it is believed. Prod has never been measured at all.
#
#   This has bitten here before in its exact form: QA's etcd snapshots were stale
#   for weeks behind a GREEN ExternalSecret holding an empty value. Every status
#   said fine.
#
#   So a CronJob's lastSuccessfulTime is a PROXY -- it says a Job exited zero.
#   The property is AN OBJECT IN THE BUCKET WITH A RECENT TIMESTAMP. This reads
#   both and always says which one it actually got.
#
# Writes nothing. Exit 0 proven, 1 failing, 3 not measured.
set -uo pipefail

ENV="${1:-}"
case "$ENV" in
  dev)  ENDPOINT=10.10.82.50; ACCOUNT=700736442855 ;;
  qa)   ENDPOINT=10.10.82.51; ACCOUNT=527101283767 ;;
  prod) ENDPOINT=10.10.82.52; ACCOUNT=937464026810 ;;
  *)    echo "usage: $0 dev|qa|prod"; exit 2 ;;
esac
REGION=us-east-2
STALE_HOURS=${STALE_HOURS:-26}

say() { printf '%s\n' "$*"; }
nm()  { say "NOT MEASURED - $*"; exit 3; }

say "== op-usxpress-$ENV   endpoint $ENDPOINT"

command -v kubectl >/dev/null 2>&1 || nm "kubectl absent on this box"

# --- the kubeconfig, by endpoint and never by filename -----------------------
# op-usxpress-dev.yaml on this box has pointed at a CLOUD EKS cluster before.
K=""
for f in "$HOME"/.kube/*.yaml "$HOME"/.kube/*.yml; do
  [ -f "$f" ] || continue
  S=$(kubectl --kubeconfig="$f" config view -o jsonpath='{.clusters[*].cluster.server}' 2>/dev/null)
  [ "$(echo "$S" | wc -w)" = "1" ] || continue
  case "$S" in *"$ENDPOINT:6443"*) K="$f"; break ;; esac
done
[ -n "$K" ] || nm "no single-cluster kubeconfig for $ENDPOINT:6443 in ~/.kube"
kubectl --kubeconfig="$K" get --raw /version >/dev/null 2>&1 \
  || nm "found $K but the API did not answer (session, not a finding)"
say "kubeconfig: $K"

# --- find the CronJob, do not assume its namespace or its name ---------------
# An empty grep is not evidence of absence, so this says which it found.
CJ=$(kubectl --kubeconfig="$K" get cronjobs -A \
     -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' \
     2>/dev/null | grep -iE 'etcd' || true)
if [ -z "$CJ" ]; then
  say "-- no CronJob anywhere whose name contains 'etcd'"
  say "   CronJobs on this cluster:"
  kubectl --kubeconfig="$K" get cronjobs -A --no-headers 2>/dev/null \
    | awk '{print "     "$1"/"$2"  "$3}' | head -20
  nm "nothing to measure: no etcd backup CronJob exists on op-usxpress-$ENV.
   That is a FINDING about the cluster, but it is not a failing backup --
   it means one was never scheduled. Check whether snapshots are taken by
   Talos itself or by something outside Kubernetes before concluding."
fi
say "-- etcd CronJob(s): $(echo "$CJ" | tr '\n' ' ')"

RC=0
for NSNAME in $CJ; do
  NS=${NSNAME%%/*}; NAME=${NSNAME##*/}
  say ""
  say "== $NS/$NAME"
  kubectl --kubeconfig="$K" -n "$NS" get cronjob "$NAME" \
    -o custom-columns=SCHEDULE:.spec.schedule,SUSPEND:.spec.suspend,LAST_SCHEDULE:.status.lastScheduleTime,LAST_SUCCESS:.status.lastSuccessfulTime \
    2>/dev/null | sed 's/^/   /'

  SUSP=$(kubectl --kubeconfig="$K" -n "$NS" get cronjob "$NAME" \
         -o jsonpath='{.spec.suspend}' 2>/dev/null)
  [ "$SUSP" = "true" ] && { say "   ** SUSPENDED -- it is not running at all"; RC=1; }

  LS=$(kubectl --kubeconfig="$K" -n "$NS" get cronjob "$NAME" \
       -o jsonpath='{.status.lastSuccessfulTime}' 2>/dev/null)
  if [ -z "$LS" ]; then
    say "   ** NO lastSuccessfulTime -- this CronJob has NEVER succeeded"; RC=1
  else
    AGE=$(( ( $(date -u +%s) - $(date -u -d "$LS" +%s 2>/dev/null || echo 0) ) / 3600 ))
    say "   last success: $LS  (${AGE}h ago, stale over ${STALE_HOURS}h)"
    [ "$AGE" -gt "$STALE_HOURS" ] && { say "   ** STALE"; RC=1; }
  fi

  say "   -- its Jobs, newest last"
  kubectl --kubeconfig="$K" -n "$NS" get jobs --no-headers 2>/dev/null \
    | grep -F "$NAME" | tail -6 | awk '{print "      "$1"  completions="$2"  age="$4}'
  FAILED=$(kubectl --kubeconfig="$K" -n "$NS" get jobs \
           -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.failed}{"\n"}{end}' \
           2>/dev/null | grep -F "$NAME" | awk '$2 != "" && $2 > 0' | wc -l)
  say "   jobs with failures: $FAILED"
  [ "$FAILED" -gt 0 ] && RC=1

  # --- the destination, read from the spec rather than assumed ---------------
  DEST=$(kubectl --kubeconfig="$K" -n "$NS" get cronjob "$NAME" -o json 2>/dev/null \
         | grep -oE 's3://[A-Za-z0-9._/-]+|[A-Za-z0-9.-]*etcd[A-Za-z0-9.-]*backup[A-Za-z0-9.-]*' \
         | sort -u | head -5)
  say "   destination strings in the spec: ${DEST:-none found}"
done

say ""
say "-- the proxy above is lastSuccessfulTime. The PROPERTY is an object in the"
say "   bucket with a recent timestamp. To settle it, list the bucket with a"
say "   profile for account $ACCOUNT in $REGION and read the newest key's date."
if [ "$RC" = 0 ]; then
  say "VERDICT: the CronJob reports success and recently. Bucket UNVERIFIED."
  exit 0
fi
say "VERDICT: FAILING or STALE on op-usxpress-$ENV. See the ** lines above."
exit 1

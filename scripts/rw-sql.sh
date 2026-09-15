#!/usr/bin/env bash
# Run read-only SQL against RisingWave on an on-prem cluster.
#
#   bash scripts/rw-sql.sh qa                      # interactive psql
#   bash scripts/rw-sql.sh qa "SHOW DATABASES;"    # one query
#   bash scripts/rw-sql.sh qa -f file.sql
#   RW_NS=risingwave-2 bash scripts/rw-sql.sh dev "SHOW SOURCES;"   # dev's second instance
#
# Port-forwards risingwave-frontend:4567 and connects with the root password from the
# cluster's own secret. The password is never printed and never written to disk.
#
# This exists because "the sync went green" is not "the object is there". Every check we
# could not make today -- does canary_promotion_mv exist, which databases exist, is the
# Brand source actually consuming -- needs a SQL session.
set -uo pipefail
ENVN="${1:-}"; shift || true
case "$ENVN" in dev|qa|prod) ;; *) echo "usage: rw-sql.sh dev|qa|prod [sql | -f file]"; exit 2 ;; esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v psql >/dev/null 2>&1 || {
  echo "psql is not installed. On this box:  sudo apt-get install -y postgresql-client"
  exit 3; }

R="$(python3 "$HERE/kube-resolve-onprem.py" "$ENVN")" || { echo "no kubeconfig serves on-prem $ENVN"; exit 4; }
export KUBECONFIG="$(printf '%s' "$R" | cut -f1)"
CTX="$(printf '%s' "$R" | cut -f2)"
echo "# op-usxpress-$ENVN -> $CTX" >&2

# RisingWave runs in the `risingwave` namespace on QA/prod; DEV RUNS TWO INSTANCES,
# `risingwave` and `risingwave-2`, and they hold different objects. RW_NS picks one.
NS="${RW_NS:-risingwave}"

# Reachability gate. Before 2026-09-15 this script went straight to `get svc` and
# reported ANY failure as "no risingwave-frontend service" -- so an expired token, a
# wrong context and a genuinely absent service all printed the same sentence. That
# was relayed upstream as fact three times in one evening. A transport failure is not
# a verdict about the cluster: abort on it, and say which it was.
if ! probe=$(kubectl --context "$CTX" get ns "$NS" 2>&1); then
  case "$probe" in
    *Unauthorized*|*"the server has asked for the credentials"*|*"error: You must be logged in"*)
      echo "CANNOT AUTHENTICATE to $ENVN as this identity -- this says nothing about $NS."
      echo "$probe" | head -2; exit 7 ;;
    *"connection refused"*|*"no such host"*|*timeout*|*"i/o timeout"*|*"context deadline"*)
      echo "CANNOT REACH the $ENVN apiserver -- this says nothing about $NS."
      echo "$probe" | head -2; exit 7 ;;
    *NotFound*|*"not found"*)
      echo "namespace $NS does not exist on $ENVN (cluster answered)."; exit 4 ;;
    *) echo "unexpected failure probing namespace $NS on $ENVN:"; echo "$probe" | head -3; exit 7 ;;
  esac
fi

# Find the frontend service rather than assuming its name. dev/QA/prod have carried
# `risingwave-frontend` and `risingwave-frontend-ext` (a NodePort); the ClusterIP one
# is what we port-forward, so prefer the name without a suffix.
SVC="$(kubectl --context "$CTX" -n "$NS" get svc -o name 2>/dev/null \
       | sed 's|^service/||' | grep -E 'frontend' | sort | head -1)"
[ -n "$SVC" ] || { echo "namespace $NS on $ENVN exists but has no frontend service:";
                   kubectl --context "$CTX" -n "$NS" get svc; exit 4; }
echo "# service: $NS/$SVC" >&2

# the root password, straight from the cluster, never echoed. Candidates are tried in
# the chosen namespace FIRST, so risingwave-2 does not silently borrow risingwave's
# password and then fail the handshake with a misleading error.
PW=""
for s in "rw-root-credentials:password:$NS" "risingwave-root-credentials:password:$NS" \
         "etl-pipeline-credentials:RW_PASSWORD:app-risingwave" "rw-root-credentials:password:risingwave"; do
  IFS=: read -r name key ns <<<"$s"
  v=$(kubectl --context "$CTX" -n "$ns" get secret "$name" -o jsonpath="{.data.$key}" 2>/dev/null | base64 -d 2>/dev/null) || true
  [ -n "$v" ] && { PW="$v"; echo "# credential: $ns/$name -> $key" >&2; break; }
done
[ -n "$PW" ] || { echo "no RisingWave root password found for namespace $NS. Secrets present:";
                  kubectl --context "$CTX" -n "$NS" get secret; exit 5; }

PORT=${RW_LOCAL_PORT:-14567}
kubectl --context "$CTX" -n "$NS" port-forward "svc/$SVC" "$PORT:4567" >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
for i in $(seq 1 20); do
  (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && break
  sleep 0.5
done
(exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null || { echo "port-forward to risingwave-frontend did not come up"; exit 6; }
echo "# 127.0.0.1:$PORT -> $NS/$SVC:4567" >&2

DB="${RW_DB:-dev}"
if [ $# -eq 0 ]; then
  PGPASSWORD="$PW" psql -h 127.0.0.1 -p "$PORT" -U root -d "$DB"
elif [ "$1" = "-f" ]; then
  PGPASSWORD="$PW" psql -h 127.0.0.1 -p "$PORT" -U root -d "$DB" -v ON_ERROR_STOP=1 -f "$2"
else
  PGPASSWORD="$PW" psql -h 127.0.0.1 -p "$PORT" -U root -d "$DB" -v ON_ERROR_STOP=1 -c "$*"
fi

#!/usr/bin/env bash
# Run read-only SQL against RisingWave on an on-prem cluster.
#
#   bash scripts/rw-sql.sh qa                      # interactive psql
#   bash scripts/rw-sql.sh qa "SHOW DATABASES;"    # one query
#   bash scripts/rw-sql.sh qa -f file.sql
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

# RisingWave runs in the `risingwave` namespace on QA/prod; dev also has risingwave-2.
NS="risingwave"
kubectl --context "$CTX" -n "$NS" get svc risingwave-frontend >/dev/null 2>&1 || {
  echo "no risingwave-frontend service in namespace $NS on $ENVN"; exit 4; }

# the root password, straight from the cluster, never echoed
PW=""
for s in etl-pipeline-credentials:RW_PASSWORD:app-risingwave rw-root-credentials:password:risingwave; do
  IFS=: read -r name key ns <<<"$s"
  v=$(kubectl --context "$CTX" -n "$ns" get secret "$name" -o jsonpath="{.data.$key}" 2>/dev/null | base64 -d 2>/dev/null) || true
  [ -n "$v" ] && { PW="$v"; echo "# credential: $ns/$name -> $key" >&2; break; }
done
[ -n "$PW" ] || { echo "could not find a RisingWave root password in this cluster"; exit 5; }

PORT=${RW_LOCAL_PORT:-14567}
kubectl --context "$CTX" -n "$NS" port-forward svc/risingwave-frontend "$PORT:4567" >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
for i in $(seq 1 20); do
  (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && break
  sleep 0.5
done
(exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null || { echo "port-forward to risingwave-frontend did not come up"; exit 6; }
echo "# 127.0.0.1:$PORT -> risingwave-frontend:4567" >&2

DB="${RW_DB:-dev}"
if [ $# -eq 0 ]; then
  PGPASSWORD="$PW" psql -h 127.0.0.1 -p "$PORT" -U root -d "$DB"
elif [ "$1" = "-f" ]; then
  PGPASSWORD="$PW" psql -h 127.0.0.1 -p "$PORT" -U root -d "$DB" -v ON_ERROR_STOP=1 -f "$2"
else
  PGPASSWORD="$PW" psql -h 127.0.0.1 -p "$PORT" -U root -d "$DB" -v ON_ERROR_STOP=1 -c "$*"
fi

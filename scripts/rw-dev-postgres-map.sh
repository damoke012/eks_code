#!/usr/bin/env bash
# Which Postgres in the `risingwave` namespace on op-usxpress-dev should the pipeline use?
#
# DEV ONLY, READ ONLY. Lists databases and table counts on each candidate server so the
# choice is made from content instead of from a service name.
#
# The question exists because the two namespaces disagree. In `risingwave-2` the pipeline's
# POSTGRES_HOST was `postgres-postgresql`, which is also that namespace's RisingWave meta
# store (database `risingwave_meta`). In `risingwave` the meta store is `pg-postgresql`
# (database `risingwave`) and a second server named `postgres-postgresql` also exists. So
# mapping by ROLE and mapping by NAME give different answers and only one can be right.
#
#   bash scripts/rw-dev-postgres-map.sh
#
# Passwords come from the namespace's own secrets and are never printed.
set -uo pipefail

KCFG="${KUBECONFIG_DEV:-/home/doke/.kube/op-usxpress-dev-fresh.yaml}"
NS=risingwave
[ -f "$KCFG" ] || { echo "no kubeconfig at $KCFG -- set KUBECONFIG_DEV"; exit 2; }
command -v psql >/dev/null || { echo "psql not installed: sudo apt-get install -y postgresql-client"; exit 3; }

# Abort on a transport failure instead of reporting it as a finding about the cluster.
if ! probe=$(kubectl --kubeconfig "$KCFG" get ns "$NS" 2>&1); then
  echo "cannot read namespace $NS on op-usxpress-dev -- this says nothing about Postgres:"
  echo "$probe" | head -2; exit 7
fi

echo "== candidate servers in $NS =="
kubectl --kubeconfig "$KCFG" -n "$NS" get svc -o name | sed 's|^service/||' \
  | grep -E '^(pg|postgres)-postgresql$' | tee /tmp/rw-pg-candidates.txt
echo

PORT=15432
for SVC in $(cat /tmp/rw-pg-candidates.txt); do
  echo "===== $SVC.$NS.svc.cluster.local"

  # Find a credential secret that actually opens THIS server. Try each, keep the first
  # that authenticates -- an unusable password looks identical to a wrong host otherwise.
  kubectl --kubeconfig "$KCFG" -n "$NS" port-forward "svc/$SVC" "$PORT:5432" >/dev/null 2>&1 &
  PF=$!
  for _ in $(seq 1 20); do (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && break; sleep 0.5; done
  if ! (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; then
    echo "  port-forward never came up -- skipping, NOT concluding anything about $SVC"
    kill $PF 2>/dev/null; echo; continue
  fi

  OPENED=""
  for SEC in pg-credentials risingwave-pg-credentials; do
    for UKEY in username user postgres-user; do
      for PKEY in password postgres-password postgresql-password; do
        U=$(kubectl --kubeconfig "$KCFG" -n "$NS" get secret "$SEC" -o jsonpath="{.data.$UKEY}" 2>/dev/null | base64 -d 2>/dev/null)
        P=$(kubectl --kubeconfig "$KCFG" -n "$NS" get secret "$SEC" -o jsonpath="{.data.$PKEY}" 2>/dev/null | base64 -d 2>/dev/null)
        [ -n "$U" ] && [ -n "$P" ] || continue
        if PGPASSWORD="$P" psql -h 127.0.0.1 -p "$PORT" -U "$U" -d postgres -At -c 'SELECT 1' >/dev/null 2>&1; then
          OPENED="$SEC/$UKEY"
          echo "  credential: $SEC (user key $UKEY)"
          echo "  -- databases and table counts --"
          PGPASSWORD="$P" psql -h 127.0.0.1 -p "$PORT" -U "$U" -d postgres -At -F' ' -c \
            "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY 1" \
          | while read -r DB; do
              N=$(PGPASSWORD="$P" psql -h 127.0.0.1 -p "$PORT" -U "$U" -d "$DB" -At -c \
                  "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema')" 2>/dev/null)
              echo "    $DB: ${N:-unreadable} tables"
            done
          break 3
        fi
      done
    done
  done
  [ -n "$OPENED" ] || echo "  no secret in $NS authenticated against $SVC -- credentials live elsewhere"
  kill $PF 2>/dev/null
  echo
done
rm -f /tmp/rw-pg-candidates.txt
echo "Pick the server whose databases hold the application's tables."
echo "A meta store database (risingwave / risingwave_meta) is RisingWave's own, not the pipeline's."

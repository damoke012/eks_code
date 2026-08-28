#!/usr/bin/env bash
# What does RisingWave on op-usxpress-DEV actually support?
# Port-forwards to the frontend and uses the LOCAL psql (the RW image has none).
# READ-ONLY except zz_probe_* objects, dropped at the end.
#
# Distinguishes transport failure from a SQL refusal by psql exit code:
#   0 = ok   2 = could not connect (ABORT — never reported as "unsupported")
#   3 = SQL error (a genuine refusal by RisingWave)
set -uo pipefail

DEV_ENDPOINT="10.10.82.50"
NS="risingwave"; DB="${RW_DB:-dev}"; PGUSER_="${RW_USER:-root}"
LPORT="${LPORT:-14567}"

command -v psql >/dev/null || { echo "psql not installed on this machine." >&2
  echo "  sudo apt-get install -y postgresql-client" >&2; exit 1; }

SRV=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
case "$SRV" in
  *"$DEV_ENDPOINT"*) ;;
  *) echo "refusing: current context points at '${SRV}', not dev ${DEV_ENDPOINT}" >&2
     echo "  export KUBECONFIG=\$HOME/.kube/op-usxpress-dev-fresh.yaml" >&2; exit 1;;
esac
echo "server ${SRV}  ns ${NS}  db ${DB}  user ${PGUSER_}"

kubectl -n "$NS" port-forward svc/risingwave-frontend "${LPORT}:4567" >/tmp/rw-pf.log 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
for i in $(seq 1 40); do
  (exec 3<>/dev/tcp/127.0.0.1/${LPORT}) 2>/dev/null && break
  sleep 0.25
done

PSQL=(psql -h 127.0.0.1 -p "$LPORT" -d "$DB" -U "$PGUSER_" -tAq -v ON_ERROR_STOP=1)
run() { "${PSQL[@]}" -c "$1" 2>/tmp/rw-err.txt; }   # stdout clean, stderr to file

echo; echo "== 0. preflight =="
out=$(run "SELECT 1;"); rc=$?
if [ "$rc" -ne 0 ] || [ "$out" != "1" ]; then
  echo "  ABORT: cannot query RisingWave (rc=${rc}, got '${out}')"
  echo "  --- psql stderr ---"; sed 's/^/  /' /tmp/rw-err.txt
  echo "  --- port-forward log ---"; sed 's/^/  /' /tmp/rw-pf.log
  exit 1
fi
echo "  SELECT 1 -> 1   connection good"

echo; echo "== 1. version =="
echo "  $(run 'SELECT version();' | head -1)"

echo; echo "== 2. what is live =="
run "SELECT 'source',count(*) FROM rw_catalog.rw_sources
     UNION ALL SELECT 'mview',count(*) FROM rw_catalog.rw_materialized_views
     UNION ALL SELECT 'sink',count(*)  FROM rw_catalog.rw_sinks
     UNION ALL SELECT 'table',count(*) FROM rw_catalog.rw_tables
     UNION ALL SELECT 'secret',count(*) FROM rw_catalog.rw_secrets;" | sed 's/^/  /'

echo; echo "== 3. replay cost proxy (rows in the Brand chain) =="
for t in mv_brand mv_brand_state; do
  v=$(run "SELECT count(*) FROM ${t};"); [ $? -eq 0 ] || v="<absent>"
  printf '  %-16s %s\n' "$t" "$v"
done

probe() { # probe <label> <sql>
  local label="$1"; run "$2" >/dev/null; local rc=$?
  case $rc in
    0) printf '  OK           %-38s\n' "$label" ;;
    3) printf '  UNSUPPORTED  %-38s %s\n' "$label" \
         "$(head -1 /tmp/rw-err.txt | cut -c1-100)" ;;
    2) printf '  CONNECTION LOST at %s — remaining results are void\n' "$label"; exit 1 ;;
    *) printf '  ERROR(rc=%s)  %-38s %s\n' "$rc" "$label" "$(head -1 /tmp/rw-err.txt)" ;;
  esac
}

echo; echo "== 4. can ALTER replace DROP?  (throwaway zz_probe_ objects) =="
run "DROP MATERIALIZED VIEW IF EXISTS zz_probe_mv CASCADE;"  >/dev/null
run "DROP MATERIALIZED VIEW IF EXISTS zz_probe_mv2 CASCADE;" >/dev/null
run "DROP TABLE IF EXISTS zz_probe_t CASCADE;" >/dev/null
probe "CREATE TABLE"              "CREATE TABLE zz_probe_t (id int PRIMARY KEY, a varchar);"
probe "ALTER TABLE ADD COLUMN"    "ALTER TABLE zz_probe_t ADD COLUMN b varchar;"
probe "CREATE MV on it"           "CREATE MATERIALIZED VIEW zz_probe_mv AS SELECT id,a FROM zz_probe_t;"
probe "ALTER MV RENAME"           "ALTER MATERIALIZED VIEW zz_probe_mv RENAME TO zz_probe_mv2;"
run "ALTER MATERIALIZED VIEW zz_probe_mv2 RENAME TO zz_probe_mv;" >/dev/null
echo "  --- these two decide everything:"
probe "ALTER MV ADD COLUMN"       "ALTER MATERIALIZED VIEW zz_probe_mv ADD COLUMN c varchar;"
probe "CREATE OR REPLACE MV"      "CREATE OR REPLACE MATERIALIZED VIEW zz_probe_mv AS SELECT id,a,'x' AS c FROM zz_probe_t;"
echo "  ---"
probe "DROP MV (no CASCADE)"      "DROP MATERIALIZED VIEW zz_probe_mv;"
probe "DROP TABLE w/ dependents"  "DROP TABLE zz_probe_t;"

echo; echo "== 5. live sources (not altered) =="
run "SELECT name FROM rw_catalog.rw_sources ORDER BY name;" | sed 's/^/  /'

echo; echo "== 6. cleanup =="
run "DROP MATERIALIZED VIEW IF EXISTS zz_probe_mv CASCADE;"  >/dev/null
run "DROP MATERIALIZED VIEW IF EXISTS zz_probe_mv2 CASCADE;" >/dev/null
run "DROP TABLE IF EXISTS zz_probe_t CASCADE;" >/dev/null
echo "  zz_probe left: mv=$(run "SELECT count(*) FROM rw_catalog.rw_materialized_views WHERE name LIKE 'zz\_probe%';") table=$(run "SELECT count(*) FROM rw_catalog.rw_tables WHERE name LIKE 'zz\_probe%';")   (both must be 0)"

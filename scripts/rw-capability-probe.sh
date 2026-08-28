#!/usr/bin/env bash
# What does RisingWave on op-usxpress-DEV actually support?
# READ-ONLY except objects prefixed zz_probe_, dropped at the end.
# Pins the environment by API endpoint, not by context name.
set -uo pipefail

DEV_ENDPOINT="10.10.82.50"
NS="risingwave"; DB="${RW_DB:-dev}"; USER="${RW_USER:-root}"

CTX="${1:-}"
if [ -z "$CTX" ]; then
  while IFS=$'\t' read -r name cluster; do
    srv=$(kubectl config view -o "jsonpath={.clusters[?(@.name=='${cluster}')].cluster.server}" 2>/dev/null)
    case "$srv" in *"$DEV_ENDPOINT"*) CTX="$name"; break;; esac
  done < <(kubectl config view -o \
      'jsonpath={range .contexts[*]}{.name}{"\t"}{.context.cluster}{"\n"}{end}' 2>/dev/null)
fi
if [ -z "$CTX" ]; then
  echo "no context found whose server contains ${DEV_ENDPOINT}. Contexts available:" >&2
  kubectl config view -o \
    'jsonpath={range .contexts[*]}{"  "}{.name}{" -> "}{.context.cluster}{"\n"}{end}' >&2
  exit 1
fi
SRV=$(kubectl --context "$CTX" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
case "$SRV" in
  *"$DEV_ENDPOINT"*) ;;
  *) echo "refusing: context '${CTX}' points at ${SRV}, not the dev endpoint ${DEV_ENDPOINT}" >&2; exit 1;;
esac

POD=$(kubectl --context "$CTX" -n "$NS" get pod -l risingwave/component=frontend \
        -o name 2>/dev/null | head -1)
[ -n "$POD" ] || { echo "no frontend pod in ${NS} on ${CTX}" >&2
                   kubectl --context "$CTX" -n "$NS" get pods 2>&1 | head -20 >&2; exit 1; }
POD="${POD#pod/}"
echo "context ${CTX}"
echo "server  ${SRV}   (dev, pinned by endpoint)"
echo "pod     ${POD}   db ${DB}"

q()  { kubectl --context "$CTX" -n "$NS" exec "$POD" -c frontend -- \
         psql -h localhost -p 4567 -d "$DB" -U "$USER" -tAq -c "$1" 2>/dev/null; }
qd() { kubectl --context "$CTX" -n "$NS" exec "$POD" -c frontend -- \
         psql -h localhost -p 4567 -d "$DB" -U "$USER" -tAq -c "$1" 2>&1; }

probe() {
  local label="$1" out
  out=$(qd "$2")
  if printf '%s' "$out" | grep -qiE 'ERROR|not supported|unsupported|permission denied'; then
    printf '  UNSUPPORTED  %-40s %s\n' "$label" \
      "$(printf '%s' "$out" | grep -iE 'ERROR|not supported' | head -1 | cut -c1-100)"
  else
    printf '  OK           %-40s\n' "$label"
  fi
}

echo; echo "== 1. version =="
echo "  $(q 'SELECT version();' | head -1)"

echo; echo "== 2. what is live =="
q "SELECT 'source',count(*) FROM rw_catalog.rw_sources
   UNION ALL SELECT 'mview',count(*) FROM rw_catalog.rw_materialized_views
   UNION ALL SELECT 'sink',count(*)  FROM rw_catalog.rw_sinks
   UNION ALL SELECT 'table',count(*) FROM rw_catalog.rw_tables
   UNION ALL SELECT 'secret',count(*) FROM rw_catalog.rw_secrets;" | sed 's/^/  /'

echo; echo "== 3. replay cost proxy (rows in the Brand chain) =="
for t in mv_brand mv_brand_state; do
  printf '  %-16s %s\n' "$t" "$(q "SELECT count(*) FROM ${t};" || true)"
done

echo; echo "== 4. can ALTER replace DROP?  (throwaway zz_probe_ objects) =="
q "DROP MATERIALIZED VIEW IF EXISTS zz_probe_mv CASCADE;" >/dev/null
q "DROP MATERIALIZED VIEW IF EXISTS zz_probe_mv2 CASCADE;" >/dev/null
q "DROP TABLE IF EXISTS zz_probe_t CASCADE;" >/dev/null
probe "CREATE TABLE"              "CREATE TABLE zz_probe_t (id int PRIMARY KEY, a varchar);"
probe "ALTER TABLE ADD COLUMN"    "ALTER TABLE zz_probe_t ADD COLUMN b varchar;"
probe "CREATE MV on it"           "CREATE MATERIALIZED VIEW zz_probe_mv AS SELECT id,a FROM zz_probe_t;"
probe "ALTER MV RENAME"           "ALTER MATERIALIZED VIEW zz_probe_mv RENAME TO zz_probe_mv2;"
q "ALTER MATERIALIZED VIEW zz_probe_mv2 RENAME TO zz_probe_mv;" >/dev/null
echo "  --- these two decide everything:"
probe "ALTER MV ADD COLUMN"       "ALTER MATERIALIZED VIEW zz_probe_mv ADD COLUMN c varchar;"
probe "CREATE OR REPLACE MV"      "CREATE OR REPLACE MATERIALIZED VIEW zz_probe_mv AS SELECT id,a,'x' AS c FROM zz_probe_t;"
echo "  ---"
probe "DROP MV without CASCADE"   "DROP MATERIALIZED VIEW zz_probe_mv;"
probe "DROP TABLE w/ dependents"  "DROP TABLE zz_probe_t;"

echo; echo "== 5. live sources (not altered) =="
q "SELECT name FROM rw_catalog.rw_sources ORDER BY name;" | sed 's/^/  /'

echo; echo "== 6. cleanup =="
q "DROP MATERIALIZED VIEW IF EXISTS zz_probe_mv CASCADE;"  >/dev/null
q "DROP MATERIALIZED VIEW IF EXISTS zz_probe_mv2 CASCADE;" >/dev/null
q "DROP TABLE IF EXISTS zz_probe_t CASCADE;" >/dev/null
echo "  zz_probe left: mv=$(q "SELECT count(*) FROM rw_catalog.rw_materialized_views WHERE name LIKE 'zz\_probe%';") table=$(q "SELECT count(*) FROM rw_catalog.rw_tables WHERE name LIKE 'zz\_probe%';")  (both must be 0)"

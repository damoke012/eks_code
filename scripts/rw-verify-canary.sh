#!/usr/bin/env bash
# Did this morning's canary actually create anything? A green sync is not an object.
#   bash scripts/rw-verify-canary.sh qa
set -uo pipefail
ENVN="${1:-qa}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "=== databases on $ENVN (settles the RW_DB dev-vs-qa question) ==="
bash "$HERE/rw-sql.sh" "$ENVN" "SHOW DATABASES;"
echo
echo "=== the canary's objects ==="
bash "$HERE/rw-sql.sh" "$ENVN" "SELECT name, relation_type FROM rw_catalog.rw_relations WHERE name LIKE 'canary%' ORDER BY name;"
echo
echo "=== what the canary materialized view says ==="
bash "$HERE/rw-sql.sh" "$ENVN" "SELECT * FROM canary_promotion_mv;"
echo
echo "=== every Kafka source present (Brand should appear once #29 lands) ==="
bash "$HERE/rw-sql.sh" "$ENVN" "SELECT name FROM rw_catalog.rw_sources ORDER BY name;"
echo
echo "=== secrets RisingWave holds (names only -- values are not readable) ==="
bash "$HERE/rw-sql.sh" "$ENVN" "SELECT name FROM rw_catalog.rw_secrets ORDER BY name;"

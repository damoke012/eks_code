#!/usr/bin/env bash
# Why does this RisingWave materialized view have zero rows?
#
#   bash scripts/rw-diagnose-empty-mv.sh qa mv_brand kafka_brand
#
# A count of 0 has at least four indistinguishable causes, and we burned an
# evening on 2026-09-11 finding out which one applied:
#
#   1. the source is still backfilling            -> wait
#   2. the topic retains no messages (low == high) -> nothing to consume
#   3. the consumer GROUP is not authorised        -> streaming fails, batch works
#   4. Avro/schema-registry decode fails           -> messages arrive, none land
#
# The count cannot tell them apart. The compute log can. This reads both and
# says which. Read-only: no writes, no restarts.
set -uo pipefail
ENVN="${1:-}"; MV="${2:-}"; SRC="${3:-}"
case "$ENVN" in dev|qa|prod) ;; *) echo "usage: rw-diagnose-empty-mv.sh dev|qa|prod <mv> <source>"; exit 2 ;; esac
[ -n "$MV" ] && [ -n "$SRC" ] || { echo "usage: rw-diagnose-empty-mv.sh dev|qa|prod <mv> <source>"; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG=$(mktemp); trap 'rm -f "$LOG"' EXIT

echo "=== 1. does the source exist, and what does the view hold ==="
bash "$HERE/rw-sql.sh" "$ENVN" \
  "SELECT name FROM rw_catalog.rw_sources WHERE name = '$SRC';
   SELECT count(*) AS rows_now FROM $MV;" 2>/dev/null || {
  echo "could not query $ENVN -- VPN, or the view does not exist"; exit 4; }

echo
echo "=== 2. what the compute node says (last 400 lines) ==="
bash "$HERE/kq.sh" "$ENVN" -n risingwave logs risingwave-compute-default-0 --tail=400 > "$LOG" 2>/dev/null || {
  echo "could not read compute logs"; exit 5; }

GROUP_ERR=$(grep -c 'GroupAuthorizationFailed' "$LOG")
AUTH_ERR=$(grep -ciE 'SaslAuthenticationFailed|TopicAuthorizationFailed|authentication fail' "$LOG")
DECODE_ERR=$(grep -ciE 'avro|schema registry|decode error|deserializ' "$LOG")
WM=$(grep 'fetch kafka watermarks' "$LOG" | tail -1)

printf '  GroupAuthorizationFailed   : %s\n' "$GROUP_ERR"
printf '  SASL / topic auth failures : %s\n' "$AUTH_ERR"
printf '  avro / registry mentions   : %s\n' "$DECODE_ERR"
printf '  last watermark line        : %s\n' "${WM:-none seen}"

LOW=""; HIGH=""
if [ -n "$WM" ]; then
  LOW=$(sed -n 's/.*low: \([0-9]*\).*/\1/p' <<<"$WM")
  HIGH=$(sed -n 's/.*high: \([0-9]*\).*/\1/p' <<<"$WM")
fi

echo
echo "=== 3. verdict ==="
VERDICT=0
if [ "$AUTH_ERR" -gt 0 ]; then
  echo "  ✗ the credentials themselves are rejected -- fix the API key before anything else"
  VERDICT=1
fi
if [ "$GROUP_ERR" -gt 0 ]; then
  echo "  ✗ the consumer GROUP is not authorised (GroupAuthorizationFailed x$GROUP_ERR)."
  echo "    The key is fine -- cluster auth and topic read work; only the group is denied."
  echo "    Needs a Confluent role binding on the group prefix this source uses:"
  echo "      SELECT name FROM rw_catalog.rw_secrets WHERE name = 'kafka_group_id_prefix';"
  echo "    Declare it in variant-inc/iaac-confluent-cloud, not by hand."
  VERDICT=1
fi
if [ -n "$LOW" ] && [ -n "$HIGH" ] && [ "$LOW" = "$HIGH" ]; then
  echo "  • the topic retains NO messages (low == high == $LOW)."
  echo "    Nothing will flow until a producer writes to it. This is not a defect,"
  echo "    and it will still read zero after every other fix. Say so before a demo."
  VERDICT=1
fi
if [ "$VERDICT" = 0 ]; then
  echo "  no group/auth failure and the topic has a backlog -- most likely still backfilling."
  echo "  Re-run in a minute; if the count does not move, read the full log rather than this summary."
fi
echo
echo "A zero count is not a diagnosis. This prints the evidence; check the log yourself before reporting."

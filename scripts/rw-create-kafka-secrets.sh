#!/usr/bin/env bash
# Create RisingWave's twelve kafka_* SECRET objects on an on-prem cluster.
#
#   bash scripts/rw-create-kafka-secrets.sh qa
#
# This is the local equivalent of the `Secret Manager` GHA workflow
# (.github/workflows/secret.yaml), which cannot run on QA until its OIDC role is
# fixed. It runs the SAME DDL from the SAME source file with the SAME values:
# pipelines/shared/000-secrets.rw, fetched from master, substituted from
# op-usxpress-<env>/risingwave/kafka.
#
# Tim's own header sanctions this path: "Run pipelines/shared/000-secrets.rw
# first (or trigger the secret.yaml GHA workflow)".
#
# No secret value is ever printed or left on disk. The workflow remains the
# durable mechanism -- this unblocks QA, it does not replace it.
set -uo pipefail

ENVN="${1:-}"
case "$ENVN" in
  dev|qa) ;;
  prod) echo "refusing: prod. op-usxpress-prod/risingwave/kafka does not exist yet -- that record is Terraform's job."; exit 2 ;;
  *) echo "usage: rw-create-kafka-secrets.sh dev|qa"; exit 2 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${AWS_PROFILE_OVERRIDE:-usx-$ENVN}"
REPO=variant-inc/risingwave-pipeline
TPL_PATH=pipelines/shared/000-secrets.rw

for c in aws jq gh python3 psql; do
  command -v "$c" >/dev/null 2>&1 || { echo "missing: $c"; exit 3; }
done

# ── 1. refuse only when a LIVE SOURCE would block the drop ────────────────
# Corrected 2026-09-11: an earlier version refused whenever kafka_* secrets
# existed, on the belief that CREATE SECRET has no IF NOT EXISTS. It does not,
# but 000-secrets.rw pairs every CREATE with a DROP SECRET IF EXISTS, so the
# file is idempotent and re-running is the normal way to pick up a rotated or
# corrected value. The real constraint is different: RisingWave refuses to drop
# a secret that a live SOURCE references. So gate on sources, not on secrets.
echo "checking $ENVN for sources that would block a secret drop..." >&2
SRC=$(bash "$HERE/rw-sql.sh" "$ENVN" "SELECT name FROM rw_catalog.rw_sources;" 2>/dev/null) || {
  echo "could not reach RisingWave on $ENVN -- is the VPN up?"; exit 4; }
if grep -qE '^ +[a-z]' <<<"$SRC"; then
  echo "refusing: $ENVN has live source(s); RisingWave will not drop a secret they reference."
  echo "$SRC" | grep -E '^ +[a-z]'
  echo
  echo "Drop the source(s) first, e.g.:"
  echo "  bash scripts/rw-sql.sh $ENVN \"DROP SOURCE IF EXISTS <name> CASCADE;\""
  echo "then re-run this. The pipeline re-creates them on the next apply."
  exit 5
fi

# ── 2. temp space that shreds itself ──────────────────────────────────────
WORK=$(mktemp -d); chmod 700 "$WORK"
cleanup() {
  [ -d "$WORK" ] && { find "$WORK" -type f -exec shred -u {} + 2>/dev/null || true; rm -rf "$WORK"; }
}
trap cleanup EXIT INT TERM

# ── 3. the DDL, from master, not from a local copy ────────────────────────
gh api "repos/$REPO/contents/$TPL_PATH" --jq .content | base64 -d > "$WORK/tpl.rw" || {
  echo "could not fetch $TPL_PATH from $REPO"; exit 6; }
[ -s "$WORK/tpl.rw" ] || { echo "fetched an empty template"; exit 6; }

# ── 4. the values, from this environment's own record ─────────────────────
aws secretsmanager get-secret-value \
  --secret-id "op-usxpress-$ENVN/risingwave/kafka" \
  --profile "$PROFILE" --region us-east-2 \
  --query SecretString --output text > "$WORK/kafka.json" || {
  echo "could not read op-usxpress-$ENVN/risingwave/kafka with profile $PROFILE"; exit 7; }

echo "# record: op-usxpress-$ENVN/risingwave/kafka ($(jq 'keys|length' "$WORK/kafka.json") keys, profile $PROFILE)" >&2

# ── 5. render, with the gates ─────────────────────────────────────────────
python3 "$HERE/render-kafka-secrets.py" \
  "$WORK/tpl.rw" "$WORK/kafka.json" "$ENVN" "$WORK/out.rw" || exit 8

# ── 6. confirm, then apply ────────────────────────────────────────────────
echo
echo "About to create 12 secrets in RisingWave database 'dev' on op-usxpress-$ENVN."
printf "Type the environment name to proceed: "
read -r REPLY
[ "$REPLY" = "$ENVN" ] || { echo "aborted."; exit 9; }

bash "$HERE/rw-sql.sh" "$ENVN" -f "$WORK/out.rw" || { echo "the DDL failed -- nothing else was run"; exit 10; }

# ── 7. verify by listing, not by exit code ────────────────────────────────
echo
echo "=== what $ENVN holds now ==="
bash "$HERE/rw-sql.sh" "$ENVN" "SELECT name FROM rw_catalog.rw_secrets ORDER BY name;"

#!/bin/bash
# Apply every .sql/.rw file under $PIPELINE_DIR that has not been applied before.
#
# Idempotent by design: a tracking table records the sha256 of each applied file. A file
# already applied with the same hash is skipped. A file whose hash has CHANGED is refused,
# not re-run — RisingWave has no read-write transactions, so a half-applied edit cannot be
# rolled back, and silently re-running an altered file is how you get divergence between
# environments.
#
# Flyway was evaluated for this and rejected: its bookkeeping needs a read-write
# transaction and types RisingWave does not accept.
set -euo pipefail

PIPELINE_DIR="${PIPELINE_DIR:-/pipeline/pipelines}"
RW_HOST="${RW_HOST:?RW_HOST not set}"
RW_PORT="${RW_PORT:-4567}"
RW_DB="${RW_DB:-dev}"
RW_USER="${RW_USER:-root}"
PG_HOST="${PG_HOST:?PG_HOST not set}"
PG_PORT="${PG_PORT:-5432}"
PG_DB="${PG_DB:-postgres}"
PG_USER="${PG_USER:-postgres}"
DRY_RUN="${DRY_RUN:-false}"

echo "pipeline dir : ${PIPELINE_DIR}"
echo "risingwave   : ${RW_USER}@${RW_HOST}:${RW_PORT}/${RW_DB}"
echo "postgres     : ${PG_USER}@${PG_HOST}:${PG_PORT}/${PG_DB}"
echo "dry run      : ${DRY_RUN}"
echo

rw()  { PGPASSWORD="${RW_PASSWORD}" psql -h "$RW_HOST" -p "$RW_PORT" -U "$RW_USER" -d "$RW_DB" -v ON_ERROR_STOP=1 "$@"; }
pg()  { PGPASSWORD="${PG_PASSWORD}" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 "$@"; }

# --- tracking table lives in Postgres, not RisingWave ------------------------------
# RisingWave rejects VARCHAR(N) and has no read-write transactions, so the bookkeeping
# belongs in the backing Postgres where an UPSERT is safe.
pg -q <<'SQL'
CREATE TABLE IF NOT EXISTS pipeline_applied (
  path        text PRIMARY KEY,
  sha256      text NOT NULL,
  applied_at  timestamptz NOT NULL DEFAULT now(),
  applied_by  text
);
SQL

shopt -s nullglob globstar
files=( "${PIPELINE_DIR}"/**/*.sql "${PIPELINE_DIR}"/**/*.rw )
IFS=$'\n' files=($(sort <<<"${files[*]-}")); unset IFS
if [ ${#files[@]} -eq 0 ]; then echo "no .sql or .rw files under ${PIPELINE_DIR}"; exit 0; fi

applied=0; skipped=0
for f in "${files[@]}"; do
  rel="${f#/pipeline/}"
  sha=$(sha256sum "$f" | cut -d' ' -f1)
  prev=$(pg -tAq -c "SELECT sha256 FROM pipeline_applied WHERE path = '${rel}'" || true)

  if [ -n "$prev" ] && [ "$prev" = "$sha" ]; then
    echo "  skip     ${rel}"; skipped=$((skipped+1)); continue
  fi
  if [ -n "$prev" ] && [ "$prev" != "$sha" ]; then
    echo "  REFUSED  ${rel}"
    echo "           already applied with a different hash."
    echo "           recorded ${prev:0:12}  file ${sha:0:12}"
    echo "           Editing an applied file cannot be rolled back. Add a new file instead."
    exit 1
  fi

  if [ "$DRY_RUN" = "true" ]; then echo "  would apply ${rel}"; continue; fi

  echo "  apply    ${rel}"
  case "$f" in
    *.rw)
      # strip sqllogictest directives so a test file can be replayed as plain SQL
      sed -e '/^statement/d' -e '/^query/d' -e '/^----$/,+0d' "$f" | rw -q -f - ;;
    *.sql) pg -q -f "$f" ;;
  esac
  pg -q -c "INSERT INTO pipeline_applied (path, sha256, applied_by) VALUES ('${rel}','${sha}','${APPLIED_BY:-argocd}')
            ON CONFLICT (path) DO UPDATE SET sha256 = EXCLUDED.sha256, applied_at = now(), applied_by = EXCLUDED.applied_by"
  applied=$((applied+1))
done

echo
echo "applied ${applied}, skipped ${skipped}"

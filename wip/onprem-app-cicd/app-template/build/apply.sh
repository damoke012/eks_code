#!/usr/bin/env bash
# Apply the SQL in this image to the RisingWave / Postgres pair in whatever
# cluster this Job is running in.
#
# Idempotent by design: Argo CD will re-run this on every sync, so a file that
# has already been applied — unchanged — must be a no-op. Tracking lives in
# Postgres, not RisingWave: RisingWave has no read-write transactions and rejects
# VARCHAR(N), which is why Flyway was ruled out (see INFRA-1491).
set -euo pipefail

: "${RW_HOST:?}"   ; : "${RW_PORT:=4567}"  ; : "${RW_DB:=dev}"   ; : "${RW_USER:?}"
: "${PG_HOST:?}"   ; : "${PG_PORT:=5432}"  ; : "${PG_DB:=postgres}" ; : "${PG_USER:?}"
: "${PIPELINE_DIR:=/pipeline/pipelines}"

log() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }

pg() { PGPASSWORD="$PG_PASSWORD" psql -v ON_ERROR_STOP=1 -qtA \
         -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" "$@"; }
rw() { PGPASSWORD="$RW_PASSWORD" psql -v ON_ERROR_STOP=1 \
         -h "$RW_HOST" -p "$RW_PORT" -U "$RW_USER" -d "$RW_DB" "$@"; }

log "ensuring tracking table"
pg -c "CREATE TABLE IF NOT EXISTS pipeline_applied (
         filename   text        NOT NULL PRIMARY KEY,
         sha256     text        NOT NULL,
         applied_at timestamptz NOT NULL DEFAULT now(),
         applied_by text        NOT NULL DEFAULT current_user
       );" >/dev/null

applied=0 ; skipped=0

# Lexical order. Prefix files 001_, 002_ … so ordering is explicit rather than
# accidental.
while IFS= read -r file; do
  name=$(basename "$file")
  hash=$(sha256sum "$file" | cut -d' ' -f1)
  seen=$(pg -c "SELECT sha256 FROM pipeline_applied WHERE filename = '${name}';")

  if [ "$seen" = "$hash" ]; then
    log "SKIP   $name (unchanged)"
    skipped=$((skipped+1))
    continue
  fi

  if [ -n "$seen" ]; then
    # The file changed after being applied. RisingWave DDL is not a migration
    # system — an edited CREATE SOURCE means dropping and recreating a streaming
    # job, which re-reads the topic. That is a decision, not something a sync
    # should make silently.
    log "ERROR  $name changed after it was applied"
    log "       recorded ${seen:0:12}…  now ${hash:0:12}…"
    log "       Give the new version a new filename, or drop the objects deliberately."
    exit 1
  fi

  case "$name" in
    *.rw)  log "APPLY  $name -> risingwave" ; rw -f "$file" ;;
    *.sql) log "APPLY  $name -> postgres"   ; pg -f "$file" >/dev/null ;;
    *)     log "SKIP   $name (unknown extension)" ; continue ;;
  esac

  pg -c "INSERT INTO pipeline_applied (filename, sha256) VALUES ('${name}', '${hash}');" >/dev/null
  applied=$((applied+1))
done < <(find "$PIPELINE_DIR" -maxdepth 1 -type f \( -name '*.sql' -o -name '*.rw' \) | sort)

log "done: ${applied} applied, ${skipped} unchanged"

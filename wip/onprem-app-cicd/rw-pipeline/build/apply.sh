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
#
# ── 2026-08-26: placeholder rendering ───────────────────────────────────────────────
# The pipeline SQL carries %NAME% placeholders for everything that varies by environment —
# topic names, endpoints, credentials. Until now nothing in the Argo CD path substituted
# them, so a file like Brand/100-sources.rw would send `topic = '%KAFKA_TOPIC_BRAND%'`
# straight to RisingWave. (`.github/workflows/secret.yaml` seds 13 names into ONE file; it
# is a GitHub Action and is not in this path at all.)
#
# Every %NAME% is now resolved from the environment: non-secret values from the overlay's
# etl-pipeline-endpoints ConfigMap, credentials from the etl-pipeline-credentials
# ExternalSecret. A file with a placeholder we cannot fill is REFUSED — silently passing a
# literal through to the database is the failure mode this exists to prevent.
#
# Deliberately generic: it discovers the placeholders in each file rather than carrying a
# list. A hardcoded list is exactly why KAFKA_TOPIC_BRAND, KAFKA_STARTUP_MODE and
# KAFKA_SCHEMA_REGISTRY_MESSAGE were missed.
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
# Directories under $PIPELINE_DIR that hold .sql/.rw files which are NOT pipeline steps.
# Regex, matched against the full path.
#   Template/  - a scaffold for authoring new pipelines. Applied, it creates junk objects
#                named after the example.
#   scripts/   - docker-compose initdb material. Its own README: "run from within the
#                container to setup the server". 100-helpers.sql uses CREATE FUNCTION with
#                no OR REPLACE, so a second run fails. It has always been inside the
#                pipelines/**/*.sql glob; renaming shared/ -> 000-shared/ only made it
#                sort early enough to notice.
EXCLUDE_RE="${EXCLUDE_RE:-/(Template|scripts)/}"

echo "pipeline dir : ${PIPELINE_DIR}"
echo "risingwave   : ${RW_USER}@${RW_HOST}:${RW_PORT}/${RW_DB}"
echo "postgres     : ${PG_USER}@${PG_HOST}:${PG_PORT}/${PG_DB}"
echo "dry run      : ${DRY_RUN}"
echo "excluding    : ${EXCLUDE_RE}"
echo

rw()  { PGPASSWORD="${RW_PASSWORD}" psql -h "$RW_HOST" -p "$RW_PORT" -U "$RW_USER" -d "$RW_DB" -v ON_ERROR_STOP=1 "$@"; }
pg()  { PGPASSWORD="${PG_PASSWORD}" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 "$@"; }

# ── rendering ──────────────────────────────────────────────────────────────────────
# %NAME% where NAME is >=2 chars, uppercase/digits/underscore. Narrow on purpose: the
# READMEs use %H% and %GRANT% as prose, and Template/ uses %VARIABLE%.
PLACEHOLDER_RE='%[A-Z][A-Z0-9_]+%'

# Writes the rendered file to stdout. NEVER logs the content — these files carry
# credentials once rendered. Only placeholder NAMES are ever printed.
render() {
  local f="$1" content name val
  local -a missing=() used=()
  content=$(cat "$f")

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ -z "${!name+x}" ] || [ -z "${!name}" ]; then
      missing+=("$name")
      continue
    fi
    val="${!name}"
    # Bash substitution, not sed: values contain /, &, | and other sed metacharacters.
    content="${content//"%${name}%"/${val}}"
    used+=("$name")
  done < <(grep -oE "$PLACEHOLDER_RE" "$f" | tr -d '%' | sort -u)

  if [ "${#missing[@]}" -gt 0 ]; then
    {
      echo "  UNRESOLVED  ${f#/pipeline/}"
      printf '              %%%s%%\n' "${missing[@]}"
      echo "              Set these in the overlay's etl-pipeline-endpoints ConfigMap"
      echo "              (non-secret) or the etl-pipeline-credentials ExternalSecret"
      echo "              (credentials). Refusing to apply a file containing a literal"
      echo "              placeholder — that is how '%KAFKA_TOPIC_BRAND%' reaches Kafka."
    } >&2
    return 1
  fi

  RENDER_USED="${used[*]-}"
  printf '%s' "$content"
}

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

applied=0; skipped=0; excluded=0
for f in "${files[@]}"; do
  rel="${f#/pipeline/}"

  if [[ "$f" =~ $EXCLUDE_RE ]]; then
    echo "  exclude  ${rel}"; excluded=$((excluded+1)); continue
  fi

  # Render BEFORE hashing. The hash is of what actually reaches the database, so changing
  # a ConfigMap value (a topic, an endpoint) counts as a change to the applied DDL and is
  # caught by the refusal below rather than silently ignored. Each cluster keeps its own
  # pipeline_applied, so per-environment values differing is expected and harmless.
  rendered=$(render "$f")
  sha=$(printf '%s' "$rendered" | sha256sum | cut -d' ' -f1)
  prev=$(pg -tAq -c "SELECT sha256 FROM pipeline_applied WHERE path = '${rel}'" || true)

  if [ -n "$prev" ] && [ "$prev" = "$sha" ]; then
    echo "  skip     ${rel}"; skipped=$((skipped+1)); continue
  fi
  if [ -n "$prev" ] && [ "$prev" != "$sha" ]; then
    echo "  REFUSED  ${rel}"
    echo "           already applied with a different hash."
    echo "           recorded ${prev:0:12}  now ${sha:0:12}"
    echo "           Editing an applied file cannot be rolled back. Add a new file instead."
    echo "           (A changed ConfigMap value also changes this hash — that is deliberate:"
    echo "            re-pointing a source at a different topic recreates the streaming job.)"
    exit 1
  fi

  if [ "$DRY_RUN" = "true" ]; then
    echo "  would apply ${rel}  [resolved: ${RENDER_USED:-none}]"
    continue
  fi

  echo "  apply    ${rel}  [resolved: ${RENDER_USED:-none}]"
  case "$f" in
    *.rw)
      # strip sqllogictest directives so a test file can be replayed as plain SQL
      printf '%s' "$rendered" | sed -e '/^statement/d' -e '/^query/d' -e '/^----$/d' | rw -q -f - ;;
    *.sql)
      printf '%s' "$rendered" | pg -q -f - ;;
  esac
  pg -q -c "INSERT INTO pipeline_applied (path, sha256, applied_by) VALUES ('${rel}','${sha}','${APPLIED_BY:-argocd}')
            ON CONFLICT (path) DO UPDATE SET sha256 = EXCLUDED.sha256, applied_at = now(), applied_by = EXCLUDED.applied_by"
  applied=$((applied+1))
done

echo
echo "applied ${applied}, skipped ${skipped}, excluded ${excluded}"

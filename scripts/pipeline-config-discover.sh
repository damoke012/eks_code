#!/usr/bin/env bash
# What config does this pipeline tree actually ASK FOR, and where does each belong?
#
# The front half of the gate. scripts/app-config-coverage.sh answers "does every
# declared variable have a home"; it needs a declaration, and until now someone
# had to write that by hand. Nobody did, so on 2026-10-21 the op-dev applier
# stopped on MONGODB_HOST, MONGODB_PORT, MONGODB_USERNAME and MONGODB_PASSWORD --
# referenced by two sinks, declared nowhere, and empty for weeks before a
# validator was added that refused to substitute blanks.
#
# This reads the tokens out of the SQL and emits that declaration.
#
# Usage:
#   bash scripts/pipeline-config-discover.sh <pipelines-dir> [--report]
#   bash scripts/pipeline-config-discover.sh --self-test
#
# Default output is the TSV app-config-coverage.sh consumes:   NAME <TAB> secret|config
# --report adds the files that reference each name, for a human.
#
# It NEVER writes a value anywhere. A secret key with no value syncs green and
# the pod gets an empty string, which is the failure this exists to prevent.
# Exits 2 if it measured nothing. Read-only.
set -uo pipefail

# Names that must go to Secrets Manager, never a values file.
SECRETISH='(password|passwd|pwd|secret|token|apikey|api_key|accesskey|access_key|privatekey|private_key|credential|sasl|clientsecret|client_secret|connectionstring|connection_string|conn_?str)'
# Names holding several facts in one string. Splitting them is how MONGODB_HOST
# came to be referenced with no possible value -- an srv URI has no port.
COMPOUND='(connectionstring|connection_string|conn_?str|_url$|_uri$|_dsn$)'

self_test(){
  local T; T=$(mktemp -d)
  mkdir -p "$T/100-Brand"
  printf "mongodb.url = 'mongodb://%%MONGODB_USERNAME%%:%%MONGODB_PASSWORD%%@%%MONGODB_HOST%%/'\n" > "$T/100-Brand/400-sink.rw"
  printf "collection = '%%MONGODB_DATABASE_BRAND%%'\n-- %%COMMENTED_OUT_VAR%%\n"              >> "$T/100-Brand/400-sink.rw"
  local OUT RC=0
  OUT=$(bash "$0" "$T" 2>&1) || RC=$?
  rm -rf "$T"
  local F=0
  check(){ if printf '%s\n' "$OUT" | grep -qF "$1"; then echo "  ok   $2"; else echo "  FAIL $2"; F=1; fi; }
  echo "self-test:"
  check "MONGODB_PASSWORD"$'\t'"secret"  "a password is classed secret"
  check "MONGODB_USERNAME"$'\t'"secret"  "a username beside a password is secret"
  check "MONGODB_HOST"$'\t'"config"      "a host is classed config"
  check "MONGODB_DATABASE_BRAND"$'\t'"config" "a database name is config"
  check "COMMENTED_OUT_VAR"              "a commented-out token is still reported"
  [ "$RC" = 0 ] && echo "  ok   exit 0 when tokens were found" || { echo "  FAIL exit $RC"; F=1; }
  exit "$F"
}
[ "${1:-}" = "--self-test" ] && self_test

DIR="${1:-}"; MODE="${2:-}"
[ -n "$DIR" ] || { echo "usage: $0 <pipelines-dir> [--report]" >&2; exit 2; }
[ -d "$DIR" ] || { echo "ABORT: $DIR is not a directory -- nothing measured" >&2; exit 2; }

# %NAME% is the substitution form the applier uses. A commented-out line still
# counts: it is what someone meant to use, and it is where the answer usually is.
NAMES=$(grep -rhoE '%[A-Z][A-Z0-9_]*%' "$DIR" 2>/dev/null | tr -d '%' | sort -u)
COUNT=$(printf '%s\n' "$NAMES" | grep -c . || true)

# Zero tokens is not "fully covered". It means the scan found nothing and a
# caller that treats that as a pass is reporting on an empty set.
if [ "${COUNT:-0}" -eq 0 ]; then
  echo "ABORT: no %VAR% tokens under $DIR -- that is not coverage, it is an empty scan" >&2
  exit 2
fi

[ "$MODE" = "--report" ] && echo "=== $COUNT variable(s) referenced under $DIR ==="

while IFS= read -r N; do
  [ -n "$N" ] || continue
  CLASS=config
  printf '%s' "$N" | grep -qiE "$SECRETISH" && CLASS=secret
  # A username sitting next to a password is a credential half, not a setting.
  printf '%s' "$N" | grep -qiE '(username|user)$' \
    && printf '%s\n' "$NAMES" | grep -qiE "^$(printf '%s' "$N" | sed -E 's/(username|user)$//i')(password|secret)$" \
    && CLASS=secret
  if [ "$MODE" = "--report" ]; then
    FILES=$(grep -rlF "%$N%" "$DIR" | sed "s|^$DIR/||" | paste -sd, -)
    FLAG=""
    printf '%s' "$N" | grep -qiE "$COMPOUND" && FLAG="  [COMPOUND - prefer this over splitting it]"
    printf '%-34s %-7s %s%s\n' "$N" "$CLASS" "$FILES" "$FLAG"
  else
    printf '%s\t%s\n' "$N" "$CLASS"
  fi
done <<< "$NAMES"

[ "$MODE" = "--report" ] && echo "=== secret -> AWS Secrets Manager. config -> the env/values file. Never invent a value. ==="
exit 0

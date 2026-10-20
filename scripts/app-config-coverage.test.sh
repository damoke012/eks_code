#!/usr/bin/env bash
# Tests for app-config-coverage.sh. The important ones are the two that must
# NOT come back green: an empty declaration, and a sensitive row whose secret
# could not be read.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/app-config-coverage.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
T=0; F=0
chk(){ T=$((T+1)); if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: expected '$3', got '$2'"; F=$((F+1)); fi; }

printf 'KAFKA_BOOTSTRAP_SERVER\tconfig\nOTEL_EXPORTER_OTLP_ENDPOINT\tconfig\n' > "$TMP/d.tsv"
printf 'kafkaBootstrapServer: KAFKA_BOOTSTRAP_SERVER\nOTEL_EXPORTER_OTLP_ENDPOINT: http://collector:4317\n' > "$TMP/values.yaml"

OUT=$(bash "$SUT" "$TMP/d.tsv" "$TMP/values.yaml" 2>&1); RC=$?
chk "all non-sensitive present -> exit 0" "$RC" "0"
chk "counts both as pass" "$(grep -c '^PASS' <<<"$OUT")" "2"

printf 'MISSING_ONE\tconfig\n' > "$TMP/miss.tsv"
OUT=$(bash "$SUT" "$TMP/miss.tsv" "$TMP/values.yaml" 2>&1); RC=$?
chk "absent from values -> exit 1" "$RC" "1"
chk "names the absent key" "$(grep -c 'MISSING_ONE' <<<"$OUT")" "1"

# An empty declaration must abort. "0 of 0 covered" is the guard failure this
# whole class of script exists to avoid.
printf '# only a comment\n\n' > "$TMP/empty.tsv"
OUT=$(bash "$SUT" "$TMP/empty.tsv" "$TMP/values.yaml" 2>&1); RC=$?
chk "empty declaration -> exit 2, not 0" "$RC" "2"
chk "says why it aborted" "$(grep -c 'declares 0 variables' <<<"$OUT")" "1"

# A sensitive row with no reachable secret is UNKNOWN, never a pass.
printf 'SOME_PASSWORD\tsecret\n' > "$TMP/sec.tsv"
OUT=$(bash "$SUT" "$TMP/sec.tsv" "$TMP/values.yaml" 2>&1); RC=$?
chk "unreadable secret -> not a pass" "$(grep -c '^PASS' <<<"$OUT")" "0"
chk "unreadable secret -> NOT MEASURED" "$(grep -c 'NOT MEASURED .*SOME_PASSWORD' <<<"$OUT")" "1"
chk "unreadable secret -> exit 0 with a warning, no false FAIL" "$RC" "0"

# A row with no class is a defect in the handover, not a pass.
printf 'NO_CLASS_HERE\n' > "$TMP/noclass.tsv"
OUT=$(bash "$SUT" "$TMP/noclass.tsv" "$TMP/values.yaml" 2>&1); RC=$?
chk "missing class column -> exit 1" "$RC" "1"
chk "unknown class -> exit 1" \
  "$(printf 'X\tmaybe\n' > "$TMP/bad.tsv"; bash "$SUT" "$TMP/bad.tsv" "$TMP/values.yaml" >/dev/null 2>&1; echo $?)" "1"

OUT=$(bash "$SUT" "$TMP/nope.tsv" "$TMP/values.yaml" 2>&1); RC=$?
chk "missing declaration file -> exit 2" "$RC" "2"

echo "$((T-F))/$T assertions passed"
[ "$F" -eq 0 ] || exit 1

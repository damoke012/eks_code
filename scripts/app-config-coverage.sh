#!/usr/bin/env bash
# Does every variable an app declares have a home in the target environment?
#
# This is the gate both 2026-10-20 onboarding calls converged on. The app team
# hands over variable NAMES tagged sensitive/non-sensitive; non-sensitive go to
# the environment's values file, sensitive go to Secrets Manager and reach the
# pod through ESO. Nothing checks that the handover is complete, and a missing
# key does not fail loudly: an empty value renders as an empty string and the
# deploy records green (see memory empty-value-renders-as-empty-string), while a
# missing telemetry endpoint lets the app run and log to nowhere.
#
# Usage:
#   bash scripts/app-config-coverage.sh <declaration.tsv> <values.yaml> [aws-profile secret-id]
#
# <declaration.tsv>  one row per variable:   NAME <TAB> secret|config
#                    '#' comments and blank lines ignored.
#
# Read-only. Prints key NAMES only -- a value never reaches the screen.
# Exits 1 on any FAIL, 0 otherwise. NOT MEASURED is never counted as a pass.
set -uo pipefail

DECL="${1:-}"; VALUES="${2:-}"; PROFILE="${3:-}"; SECRET_ID="${4:-}"

if [ -z "$DECL" ] || [ -z "$VALUES" ]; then
  echo "usage: $0 <declaration.tsv> <values.yaml> [aws-profile secret-id]" >&2
  exit 2
fi
for f in "$DECL" "$VALUES"; do
  [ -f "$f" ] || { echo "ABORT: $f does not exist -- nothing measured" >&2; exit 2; }
done

# An empty declaration must abort, not pass. A guard that reports "all covered"
# over zero rows is the exact failure recorded in a-guard-can-measure-the-wrong-thing.
ROWS=$(grep -cvE '^[[:space:]]*(#|$)' "$DECL" || true)
if [ "${ROWS:-0}" -eq 0 ]; then
  echo "ABORT: $DECL declares 0 variables -- that is not coverage, it is an empty file" >&2
  exit 2
fi

PASS=0; FAIL=0; SKIP=0
ok(){   printf 'PASS         %s\n' "$1"; PASS=$((PASS+1)); }
bad(){  printf 'FAIL         %s\n' "$1"; FAIL=$((FAIL+1)); }
skip(){ printf 'NOT MEASURED %s\n' "$1"; SKIP=$((SKIP+1)); }

echo "=== config coverage: $ROWS declared variable(s) ==="
echo "    declaration: $DECL"
echo "    values file: $VALUES"

# ── the sensitive side: enumerate the secret's key names once ────────────────
SECRET_KEYS=""
SECRET_READABLE=0
if [ -n "$SECRET_ID" ]; then
  if [ -z "$PROFILE" ]; then
    skip "secret: a secret id was given with no aws profile -- refusing to guess the account"
  elif ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    skip "secret: aws or jq absent on this box"
  else
    # No 2>/dev/null: an auth failure must not read as an empty secret.
    RAW=$(aws secretsmanager get-secret-value --profile "$PROFILE" \
            --secret-id "$SECRET_ID" --query SecretString --output text)
    RC=$?
    if [ "$RC" -ne 0 ] || [ -z "$RAW" ]; then
      skip "secret: could not read $SECRET_ID via profile $PROFILE (exit $RC) -- every sensitive row below is UNKNOWN, not absent"
    else
      SECRET_KEYS=$(printf '%s' "$RAW" | jq -r 'keys[]' 2>/dev/null)
      unset RAW
      if [ -z "$SECRET_KEYS" ]; then
        skip "secret: $SECRET_ID is not a flat JSON object -- cannot enumerate key names"
      else
        SECRET_READABLE=1
        echo "    secret:      $SECRET_ID ($(printf '%s\n' "$SECRET_KEYS" | wc -l) keys) via $PROFILE"
      fi
    fi
  fi
else
  skip "secret: no secret id given -- the sensitive side of the split was not checked"
fi

echo
while IFS=$'\t' read -r NAME CLASS _rest; do
  case "$NAME" in ''|\#*) continue ;; esac
  NAME="${NAME%%[[:space:]]*}"
  CLASS=$(printf '%s' "${CLASS:-}" | tr -d '[:space:]')
  case "$CLASS" in
    config)
      if grep -qw -- "$NAME" "$VALUES"; then
        ok "$NAME -> present in $(basename "$VALUES")"
      else
        bad "$NAME -> declared non-sensitive and ABSENT from $(basename "$VALUES")"
      fi
      ;;
    secret)
      if [ "$SECRET_READABLE" -ne 1 ]; then
        skip "$NAME -> sensitive, secret not readable"
      elif printf '%s\n' "$SECRET_KEYS" | grep -qx -- "$NAME"; then
        ok "$NAME -> present as a key in the secret"
      else
        bad "$NAME -> declared sensitive and MISSING from the secret"
      fi
      ;;
    '')
      bad "$NAME -> no class column. Every row needs 'secret' or 'config'"
      ;;
    *)
      bad "$NAME -> unknown class '$CLASS'. Only 'secret' or 'config'"
      ;;
  esac
done < "$DECL"

# ── the other direction: what exists that nobody declared ───────────────────
if [ "$SECRET_READABLE" -eq 1 ]; then
  echo
  while IFS= read -r K; do
    [ -n "$K" ] || continue
    if ! awk -F'\t' -v k="$K" '$1==k{found=1} END{exit !found}' "$DECL"; then
      echo "ORPHAN       $K -> in the secret, in nobody's declaration"
    fi
  done <<< "$SECRET_KEYS"
fi

echo
echo "=== $PASS pass, $FAIL fail, $SKIP not measured ==="
[ "$SKIP" -gt 0 ] && echo "NOT MEASURED is not a pass. Resolve those before calling the handover complete."
[ "$FAIL" -gt 0 ] && exit 1
exit 0

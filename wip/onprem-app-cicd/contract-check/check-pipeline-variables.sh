#!/usr/bin/env bash
# Check A -- every %VAR% in the pipeline SQL is a variable the platform supplies.
#
# This is apply.sh's render() check, moved to the developer's pull request. apply.sh
# already refuses a file whose %VAR% is unset or empty, but it can only do that in the
# environment it is running in: inside an Argo sync-hook Job whose log is deleted on
# failure. By then the merge has happened and the build has run.
#
# What this adds is not coverage, it is TIMING and PLACE: the same verdict, in the PR,
# against a contract that is the same in every environment.
#
# It deliberately does NOT read any environment's values file. A variable that is in the
# contract but empty in QA is a different defect, caught by check B in the chart repo.
set -euo pipefail

SQL_DIR="${1:-pipelines}"
CONTRACT="${2:-contracts/pipeline-variables.txt}"
MODE="${MODE:-fail}"            # fail | warn
# Mirrors apply.sh. Keep these two lines byte-identical to it or this check measures
# something adjacent to what actually runs.
PLACEHOLDER_RE='%[A-Z][A-Z0-9_]+%'
EXCLUDE_RE="${EXCLUDE_RE:-/(Template|scripts)/}"

[ -d "$SQL_DIR" ]    || { echo "::error::sql dir '$SQL_DIR' does not exist"; exit 1; }
[ -f "$CONTRACT" ]   || { echo "::error::contract '$CONTRACT' does not exist"; exit 1; }

# The contract: one NAME per line, # comments and blanks ignored.
mapfile -t ALLOWED < <(grep -oE '^[A-Z][A-Z0-9_]+' "$CONTRACT" | sort -u)
[ "${#ALLOWED[@]}" -gt 0 ] || { echo "::error::contract parsed to 0 names -- wrong format"; exit 1; }

shopt -s nullglob globstar
all=( "$SQL_DIR"/**/*.sql "$SQL_DIR"/**/*.rw )
[ "${#all[@]}" -gt 0 ] || { echo "::error::no .sql or .rw files under '$SQL_DIR'"; exit 1; }

selected=(); excluded=()
for f in "${all[@]}"; do
  if [[ "/$f" =~ $EXCLUDE_RE ]]; then excluded+=("$f"); else selected+=("$f"); fi
done

echo "sql dir      : $SQL_DIR"
echo "contract     : $CONTRACT  (${#ALLOWED[@]} names)"
echo "excluding    : $EXCLUDE_RE"
echo "files        : ${#all[@]} found, ${#selected[@]} selected, ${#excluded[@]} excluded"

# An exclusion regex that matches nothing is the failure that produced a 27-value error
# report in October: it reads as "nothing to exclude" and is indistinguishable from a
# regex whose paths were renamed under it. Print the measurement beside the threshold.
if [ "$EXCLUDE_RE" != '' ] && [ "${#excluded[@]}" -eq 0 ]; then
  echo "::warning::EXCLUDE_RE '$EXCLUDE_RE' matched 0 of ${#all[@]} files -- verify it still names real paths"
fi
[ "${#selected[@]}" -gt 0 ] || { echo "::error::every file was excluded -- nothing would be applied"; exit 1; }

printf '%s\n' "${excluded[@]}" | sed 's/^/  excluded: /'
echo

unknown_names=(); used_names=()
for f in "${selected[@]}"; do
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    used_names+=("$name")
    found=0
    for a in "${ALLOWED[@]}"; do [ "$a" = "$name" ] && { found=1; break; }; done
    if [ "$found" -eq 0 ]; then
      unknown_names+=("$name")
      echo "  NOT IN CONTRACT  %${name}%  <- ${f}"
    fi
  done < <(grep -oE "$PLACEHOLDER_RE" "$f" | tr -d '%' | sort -u)
done

mapfile -t used_uniq    < <(printf '%s\n' "${used_names[@]-}"    | sort -u | sed '/^$/d')
mapfile -t unknown_uniq < <(printf '%s\n' "${unknown_names[@]-}" | sort -u | sed '/^$/d')

echo
echo "placeholders used : ${#used_uniq[@]} distinct"
echo "not in contract   : ${#unknown_uniq[@]} distinct"

# Informational only. A contract entry no SQL references is not an error -- it may be
# consumed by apply.sh itself (the four POSTGRES_ENTITY_* values) rather than by a file.
for a in "${ALLOWED[@]}"; do
  u=0; for n in "${used_uniq[@]-}"; do [ "$n" = "$a" ] && { u=1; break; }; done
  [ "$u" -eq 0 ] && echo "  unused in SQL: $a"
done

echo
if [ "${#unknown_uniq[@]}" -eq 0 ]; then
  echo "PASS - every placeholder is a variable the platform supplies"
  exit 0
fi
printf '%s\n' "${unknown_uniq[@]}" | sed 's/^/  /'
echo
echo "Each of these is one of three things:"
echo "  1. a typo in the SQL"
echo "  2. a RisingWave CREATE SECRET name, which is referenced as \`secret <name>\`"
echo "     in SQL and is NEVER substituted as an environment variable"
echo "  3. a genuinely new variable -- then it needs a PR to the contract AND a value"
echo "     in every environment's values file, or promotion breaks after dev"
if [ "$MODE" = 'warn' ]; then
  echo "::warning::MODE=warn, not failing the build"
  exit 0
fi
exit 1

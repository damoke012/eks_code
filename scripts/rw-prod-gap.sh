#!/usr/bin/env bash
# INFRA-1674 kick-off: what does op-qa ship for RisingWave that op-prod does not?
#
# READ ONLY. Reads two branches of iaac-talos-flux-platform and reports three lists:
#   QA-ONLY   files to create on op-prod
#   BOTH      files that exist on both but differ
#   PROD-ONLY files prod has that QA does not (usually a surprise worth reading)
#
# It then scans every QA-only file for identifiers that MUST change for prod. CLAUDE.md
# rule 7 and [[manifests-copied-across-branches]]: op-qa and op-prod manifests have
# previously carried DEV role ARNs. A copy that "works" is not evidence it is correct.
#
#   scripts/rw-prod-gap.sh ~/pr-work/iaac-talos-flux-platform
#   scripts/rw-prod-gap.sh ~/pr-work/iaac-talos-flux-platform --show   # print the diffs
set -uo pipefail

CHECKOUT="${1:-}"; SHOW=0
[ "${2:-}" = "--show" ] && SHOW=1
if [ -z "$CHECKOUT" ] || [ ! -d "$CHECKOUT/.git" ]; then
  echo "usage: $0 <path-to-iaac-talos-flux-platform-checkout> [--show]" >&2
  exit 1
fi
FROM="${FROM_BRANCH:-op-qa}"
TO="${TO_BRANCH:-op-prod}"
PATHSPEC='infrastructure/'

cd "$CHECKOUT" || exit 1
echo "repo   : $(git remote get-url origin 2>/dev/null)"
echo "compare: origin/${FROM}  ->  origin/${TO}"
git fetch --quiet origin "$FROM" "$TO" 2>/dev/null || echo "  (fetch failed — using local refs)"
for b in "$FROM" "$TO"; do
  git rev-parse --verify --quiet "origin/$b" >/dev/null || { echo "no origin/$b" >&2; exit 1; }
done
echo "         ${FROM}=$(git rev-parse --short origin/$FROM)  ${TO}=$(git rev-parse --short origin/$TO)"

listrw() { git ls-tree -r --name-only "origin/$1" -- "$PATHSPEC" 2>/dev/null | grep -i risingwave; }
A=$(listrw "$FROM" | sort)
B=$(listrw "$TO"   | sort)

echo
echo "=== QA-ONLY — must be created on ${TO} ($(comm -23 <(echo "$A") <(echo "$B") | grep -c . )) ==="
comm -23 <(echo "$A") <(echo "$B") | sed 's/^/  /'
echo
echo "=== PROD-ONLY — ${TO} has these and ${FROM} does not ($(comm -13 <(echo "$A") <(echo "$B") | grep -c . )) ==="
comm -13 <(echo "$A") <(echo "$B") | sed 's/^/  /'
echo
echo "=== ON BOTH BUT DIFFERENT ==="
n=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if ! git diff --quiet "origin/${FROM}:${f}" "origin/${TO}:${f}" 2>/dev/null; then
    echo "  DIFFERS  $f"; n=$((n+1))
    [ "$SHOW" -eq 1 ] && git diff "origin/${FROM}:${f}" "origin/${TO}:${f}" | sed 's/^/      /'
  fi
done < <(comm -12 <(echo "$A") <(echo "$B"))
[ "$n" -eq 0 ] && echo "  (none)"

echo
echo "=== identifiers in the QA-only files that MUST change for prod ==="
echo "    dev 700736442855 | qa 527101283767 | PROD 937464026810 | ecr 064859874041"
echo "    op-dev 10.10.82.50 | op-qa 10.10.82.51 | PROD 10.10.82.52"
echo "    oidc dev d3a7wcnazdrd6p | qa d2t7d36wmf0hbm | PROD d3rxit8f4yvshu"
echo
hits=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  body=$(git show "origin/${FROM}:${f}" 2>/dev/null) || continue
  found=$(printf '%s' "$body" | grep -noE \
    '527101283767|700736442855|op-usxpress-qa|op-usxpress-dev|10\.10\.82\.5[01]|d2t7d36wmf0hbm|d3a7wcnazdrd6p|\.op-qa\.|\.op-dev\.' || true)
  if [ -n "$found" ]; then
    echo "  ${f}"
    printf '%s\n' "$found" | sort -t: -k2 | uniq -f0 | head -12 | sed 's/^/      line /'
    hits=$((hits+1))
  fi
done < <(comm -23 <(echo "$A") <(echo "$B"))
[ "$hits" -eq 0 ] && echo "  none found — verify the grep matched something before believing this"

echo
echo "Next: build the prod PR FROM origin/${TO}, not from wip/. Read git diff origin/${TO}"
echo "in full before pushing, including hunks you did not intend. iaac-talos-flux-platform"
echo "AUTO-MERGES on green, so the PR is the deploy."

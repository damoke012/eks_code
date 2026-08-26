#!/usr/bin/env bash
# Write everything needed to review variant-inc/risingwave-pipeline into ONE bounded file.
#
#   bash ~/eks_code/scripts/rw-pipeline-review-bundle.sh ~/repos/risingwave-pipeline
#
# Produces ~/rw-review-bundle.md. Includes, in full: the workflows, the applier, the deploy
# overlays, and every pipeline .rw/.sql -- these are what the review turns on. Excludes:
# upstream Grafana dashboards, docker/ local-dev config, archive/, lock files. Docs get
# their first 25 lines only.
#
# ⚠️ THIS FILE CONTAINS variant-inc SOURCE. Keep it on the corp machine. Do NOT commit it
# into eks_code or any personal repo -- that is what CLAUDE.md rule 10 forbids. Credentials
# are redacted below, but source is source.
set -uo pipefail
REPO="${1:-}"; OUT="${2:-$HOME/rw-review-bundle.md}"
[ -d "${REPO}/.git" ] || { echo "usage: $0 <clone> [outfile]" >&2; exit 2; }
case "$(git -C "$REPO" remote get-url origin)" in
  *variant-inc/risingwave-pipeline*) ;;
  *) echo "!! not the risingwave-pipeline clone" >&2; exit 2 ;;
esac

red() { python3 -c '
import sys, re
KEYS = re.compile(r"(password|secret|username|api[_.]?key|token|credential)", re.I)
Q = re.compile(r"""(\x27)([^\x27\n]{12,})(\x27)""")
for l in sys.stdin:
    if KEYS.search(l): l = Q.sub(lambda m: "\x27<REDACTED %d>\x27" % len(m.group(2)), l)
    sys.stdout.write(l)
'; }

G() { git -C "$REPO" "$@"; }
EXCL='\.json$|^docker/|^archive/|\.lock$|postgresql\.conf|pg_hba\.conf|risingwave\.toml|package-lock|yarn\.lock'

{
echo "# risingwave-pipeline — review bundle"
echo
echo "origin \`$(G remote get-url origin)\` · branch \`$(G rev-parse --abbrev-ref HEAD)\`"
echo "generated from $(G log -1 --format='%h %ad' --date=short)"
echo
echo "## Branches"; echo '```'; G branch -r; echo '```'
echo "## Last 30 commits"; echo '```'
G log -30 --format='%h %ad %-20an %s' --date=short; echo '```'

echo "## Tree (excluding dashboards, docker/, archive/)"; echo '```'
G ls-files | grep -vE "$EXCL" ; echo '```'
echo "## Excluded, for completeness"; echo '```'
G ls-files | grep -E "$EXCL" | sed 's/$/  [excluded]/'; echo '```'

for f in $(G ls-files '.github/workflows/*' 'build/*' 'deploy/*' | grep -vE "$EXCL"); do
  echo; echo "## \`$f\`"; echo '```'; red < "$REPO/$f"; echo '```'
done

echo; echo "## Pipelines — every .rw and .sql, in full"
for f in $(G ls-files 'pipelines/*' | grep -E '\.(rw|sql)$'); do
  echo; echo "### \`$f\`  ·  $(G log -1 --format='%ad %an' --date=short -- "$f")"
  echo '```sql'; red < "$REPO/$f"; echo '```'
done
echo; echo "### other files under pipelines/"; echo '```'
G ls-files 'pipelines/*' | grep -vE '\.(rw|sql)$'; echo '```'

echo; echo "## %VAR% placeholders and who substitutes them"
echo '```'
echo "-- placeholders used:"
G grep -ohE '%[A-Z0-9_]+%' -- . 2>/dev/null | sort | uniq -c | sort -rn
echo
echo "-- candidate substituters (envsubst / sed / expansion), outside pipelines/:"
G grep -nE 'envsubst|sed .*%|\$\{[A-Z_]+\}' -- '*.sh' '*.yml' '*.yaml' 'Dockerfile*' 2>/dev/null \
  | grep -v '^pipelines/' | head -40
echo '```'

echo; echo "## Credential sweep"
echo '```'
echo "-- working tree, quoted literal after a credential key:"
G grep -lE "(sasl|schema\.registry)\.(username|password)[[:space:]]*=[[:space:]]*'" -- . 2>/dev/null || echo "   none"
echo
echo "-- HISTORY (a fix commit does not unpublish a pushed secret):"
G log --oneline -S"properties.sasl.password = '" --all 2>/dev/null | head -15
echo '```'

echo; echo "## Docs — first 25 lines each"
for f in $(G ls-files '*.md' | grep -vE '^archive/|^docker/'); do
  echo; echo "### \`$f\` ($(wc -l < "$REPO/$f") lines)"
  echo '```'; head -25 "$REPO/$f" | red; echo '```'
done
} > "$OUT" 2>&1

echo "wrote $OUT  ($(wc -l < "$OUT") lines, $(du -h "$OUT" | cut -f1))"
echo
echo "Paste it in slices:"
echo "  sed -n '1,250p'   $OUT"
echo "  sed -n '251,500p' $OUT"
echo "  ... "
echo
echo "⚠️  Contains variant-inc source. Keep it on this machine -- do not commit it to eks_code."

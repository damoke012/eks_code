#!/usr/bin/env bash
# Knowledge-base rot detector. Read-only — reports, never edits.
set -uo pipefail
cd "$(dirname "$0")/.."
findings=0
note() { printf '  %s\n' "$1"; findings=$((findings+1)); }

echo "== kb-lint"

# 1. Notes referencing files that no longer exist.
while IFS= read -r ref; do
  f="${ref#*:}"; src="${ref%%:*}"
  [ -e "$f" ] || note "dead ref: $src -> $f"
done < <(grep -rhoE '\((wip|docs|scripts|iaac-drafts)/[A-Za-z0-9._/-]+\)' wip docs 2>/dev/null \
         | tr -d '()' | sed 's/^/x:/' | sort -u | head -40)

# 2. Undated numeric claims — a number without a date cannot be trusted later.
n=$(grep -rlE '^[^|]*\b[0-9]{2,}\b' wip --include='*.md' 2>/dev/null \
    | xargs -r grep -LE '20[0-9]{2}-[0-9]{2}-[0-9]{2}' 2>/dev/null | wc -l)
[ "$n" -gt 0 ] && note "$n note(s) carry numbers but no ISO date"

# 3. Stale TODO/FIXME older than 90 days by the date in the line.
cutoff=$(date -d '90 days ago' +%Y-%m-%d 2>/dev/null || echo 0000-00-00)
while IFS= read -r line; do
  d=$(printf '%s' "$line" | grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}' | head -1)
  [ -n "$d" ] && [ "$d" \< "$cutoff" ] && note "stale TODO ($d): $(printf '%s' "$line" | cut -c1-80)"
done < <(grep -rnE '(TODO|FIXME)' wip docs --include='*.md' 2>/dev/null | head -40)

if [ "$findings" -eq 0 ]; then echo "kb-lint: clean"; else echo "kb-lint: $findings finding(s)"; fi
exit 0

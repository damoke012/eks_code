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

# 2. Undated MEASUREMENT claims. The house rule is that a claim carries a scope and a
#    timestamp — not that every digit does. An earlier version flagged any file containing a
#    2+ digit number, which caught AWS account ids, INFRA- ticket numbers and EXERCISE-05
#    filenames: 57 hits, ~0 real. A check that fires on everything retires the suspicion just
#    as effectively as one that cannot fire.
out=$(python3 - <<'PYLINT'
import os, re
MEASURE = re.compile(r"""\b\d+(?:\.\d+)?\s*(?:%|ms|GiB?|MiB?|[KMGT]B|
    x|\u00d7|pods?|nodes?|replicas?|containers?|namespaces?|clusters?|
    weeks?|days?|hours?|hrs?|minutes?|mins?|seconds?|secs?|
    failures?|errors?|retries|restarts?|requests?|rps|qps)\b""", re.X | re.I)
ISO  = re.compile(r"20\d{2}-\d{2}-\d{2}")
# identifiers that are NOT measurements
SKIP = re.compile(r"(INFRA-\\d+|PR\\s*#\\d+|\\b\\d{12}\\b|v?\\d+\\.\\d+\\.\\d+|:\\d{2,5}\\b|EXERCISE-\\d+"
                  r"|requests?:|limits?:|storage:|memory:|cpu:|size:|replicas:|PVC\\b)", re.I)
hits = []
SPEC_DIRS = ("interview-", "app-template", "/templates/", "exercises")
for root, _, files in os.walk("wip"):
    # Exercise material, templates and scaffolding state SPEC values (10Gi, 25 min, 12 replicas).
    # The house rule targets OBSERVATIONS, which decay. A spec does not.
    if any(k in root for k in SPEC_DIRS): continue
    for fn in files:
        if not fn.endswith(".md"): continue
        f = os.path.join(root, fn)
        try: t = open(f, encoding="utf-8", errors="replace").read()
        except OSError: continue
        if ISO.search(t): continue
        for line in t.splitlines():
            if SKIP.search(line): continue
            m = MEASURE.search(line)
            if m:
                hits.append((f, m.group(0).strip(), line.strip()[:60])); break
for f, m, line in hits[:10]:
    print(f"undated claim: {f} -> '{m}'  in: {line}")
print(f"__COUNT__{len(hits)}")
PYLINT
)
cnt=$(printf '%s' "$out" | sed -n 's/^__COUNT__//p')
printf '%s' "$out" | grep -v '^__COUNT__' | while IFS= read -r l; do [ -n "$l" ] && note "$l"; done
[ "${cnt:-0}" -gt 10 ] && note "... and $((cnt-10)) more undated measurement claim(s)"

# 3. Stale TODO/FIXME older than 90 days by the date in the line.
cutoff=$(date -d '90 days ago' +%Y-%m-%d 2>/dev/null || echo 0000-00-00)
while IFS= read -r line; do
  d=$(printf '%s' "$line" | grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}' | head -1)
  [ -n "$d" ] && [ "$d" \< "$cutoff" ] && note "stale TODO ($d): $(printf '%s' "$line" | cut -c1-80)"
done < <(grep -rnE '(TODO|FIXME)' wip docs --include='*.md' 2>/dev/null | head -40)

if [ "$findings" -eq 0 ]; then echo "kb-lint: clean"; else echo "kb-lint: $findings finding(s)"; fi
exit 0

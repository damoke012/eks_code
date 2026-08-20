#!/usr/bin/env bash
# Periodic health check for the knowledge base and the agent wiring itself.
# Read-only: reports, never edits. Run it weekly, or after a burst of work.
set -uo pipefail
cd "$(dirname "$0")/.."
findings=0
section() { printf '\n== %s\n' "$1"; }
fence()   { printf '%s\n' "$1" | sed 's/^/  /'; }

section "1. Knowledge-base rot"
out=$(bash scripts/kb-lint.sh 2>&1); fence "$out"
printf '%s' "$out" | grep -q 'clean' || findings=$((findings+1))

section "2. Skill descriptions — do they match how requests arrive?"
for d in .claude/skills/*/; do
  n=$(basename "$d"); f="$d/SKILL.md"
  [ -f "$f" ] || continue
  if ! head -1 "$f" | grep -q '^---'; then
    fence "MISSING FRONTMATTER: $n — the router drops it entirely"; findings=$((findings+1)); continue
  fi
  desc=$(sed -n '/^description:/,/^[a-z-]*:/p' "$f" | head -1 | cut -c14-)
  len=${#desc}
  if [ "$len" -lt 60 ]; then
    fence "THIN ($len chars): $n — add the literal words a real request would use"; findings=$((findings+1))
  else
    fence "ok ($len chars): $n"
  fi
done

section "3. Upstream skills — is the pin still current?"
if [ -f "$HOME/.claude/skills/.mattpocock-skills.install.json" ]; then
  pin=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.claude/skills/.mattpocock-skills.install.json')))['commit'])")
  head=$(git ls-remote https://github.com/mattpocock/skills.git HEAD 2>/dev/null | cut -f1)
  if [ -n "$head" ] && [ "$pin" != "$head" ]; then
    fence "upstream moved: pinned ${pin:0:8}, HEAD ${head:0:8} — review, then re-run bootstrap.sh --force"
    findings=$((findings+1))
  else
    fence "pin ${pin:0:8} is current"
  fi
else
  fence "no upstream skills installed"
fi

section "4. Guard hook"
if [ -f .claude/hooks/guard-mutations.sh ]; then
  out=$(bash .claude/hooks/guard-mutations.test.sh 2>&1 | tail -1); fence "$out"
  printf '%s' "$out" | grep -q 'failed 0' || findings=$((findings+1))
  grep -q "^PROTECTED=''" .claude/hooks/guard-mutations.sh && { fence "guard is INERT — PROTECTED empty"; findings=$((findings+1)); }
  python3 -c "
import json,os
p=os.path.expanduser('~/.claude/settings.json'); d=json.load(open(p)) if os.path.exists(p) else {}
reg=any('guard-mutations' in h.get('command','') for e in d.get('hooks',{}).get('PreToolUse',[]) for h in e.get('hooks',[]))
print('  registered as PreToolUse' if reg else '  NOT REGISTERED — the guard exists but never runs')" 
else
  fence "no guard hook"
fi

section "5. Environment backup freshness"
if [ -d .claude-env ]; then
  age=$(( ( $(date +%s) - $(stat -c %Y .claude-env 2>/dev/null || echo 0) ) / 86400 ))
  fence ".claude-env is ${age}d old"; [ "$age" -gt 7 ] && findings=$((findings+1))
else
  fence "no .claude-env — a rebuild would destroy skills, router and memory"; findings=$((findings+1))
fi

printf '\nweekly-maintenance: %s finding(s)\n' "$findings"
exit 0

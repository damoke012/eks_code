#!/usr/bin/env bash
# Re-embed the live router into scripts/bootstrap-skills.sh.
# bootstrap-skills.sh WRITES the router; if the live one is fixed and the embedded copy is not,
# the next --force silently reverts the fix. Run this after editing the router.
set -uo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import os, re
boot = 'scripts/bootstrap-skills.sh'
live = os.path.expanduser('~/.claude/skills-router/inject.sh')
s = open(boot).read()
body = open(live).read()
if not body.endswith('\n'): body += '\n'
start_tag = "cat > \"$ROUTER/inject.sh\" <<'ROUTER_INJECT'\n"
end_tag = "ROUTER_INJECT\n"
i = s.index(start_tag) + len(start_tag)
j = s.index(end_tag, i)
if s[i:j] == body:
    print("  router already in sync"); raise SystemExit(0)
open(boot, 'w').write(s[:i] + body + s[j:])
print(f"  embedded router updated ({len(body.splitlines())} lines)")
PY

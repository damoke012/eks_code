#!/usr/bin/env bash
# Every script that WRITES to Jira must prove its token first. Read-only — reports, never edits.
#
# Why this exists. Jira answers an unauthorised issue read with 404 "does not exist" and an
# unauthorised create with 400 "the target project doesn't exist". Neither says "bad token",
# so a wrong credential is indistinguishable from a missing ticket or a permissions problem.
# It has now cost two sessions: 2026-08-20 (eleven failed calls) and 2026-09-03 (nine), both
# from a placeholder token pasted straight out of an instruction.
#
# close-sprint3-tickets.py grew a preflight() after the first one. The two scripts that failed
# the second time were written later, with their own copy of api(), and never called it. A
# check that lives as a docstring in one module does not reach the next module. Hence a linter.
set -uo pipefail
cd "$(dirname "$0")/.."
findings=0

echo "== lint-jira-preflight"

for f in scripts/*.py; do
  # Only scripts that actually talk to Jira.
  grep -q 'atlassian\.net' "$f" || continue

  # Only scripts that MUTATE. A read-only reporter has nothing to fail closed about:
  # its 404 is visible in its own output, which is the whole of what it does.
  grep -qE '"(POST|PUT|DELETE)"' "$f" || continue

  # Either its own preflight, or a call into the shared one.
  if grep -qE 'preflight|/rest/api/3/myself' "$f"; then
    continue
  fi

  printf '  no auth preflight: %s\n' "$f"
  findings=$((findings+1))
done

if [ "$findings" -eq 0 ]; then
  echo "  ok — every mutating Jira script proves its token first"
else
  echo
  echo "  Add before the first write:"
  echo "      s, r = api(\"GET\", \"/rest/api/3/myself\")"
  echo "      if s != 200: sys.exit(f\"cannot authenticate (HTTP {s})\")"
  echo "  or call m.preflight() if the script already imports close-sprint3-tickets.py."
fi

exit $(( findings > 0 ))

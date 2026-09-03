#!/usr/bin/env bash
# Every PR builder that pushes a branch must hand over a base-pinned `gh pr create`.
# Read-only — reports, never edits.
#
# Why. iaac-talos-flux-platform has a branch PER CLUSTER (op-dev, op-qa, op-prod) and its
# default branch is op-dev. The "Create a pull request" link git prints after a push opens
# the compare page with base=op-dev, so a change built from origin/op-prod is offered for
# merge into DEV. On 2026-09-03 that page was one click from putting prod's Grafana hostname
# and prod's ten ingress IPs onto the dev cluster, breaking a route that works.
#
# It does not look like a mistake. The tells are subtle: "Can't automatically merge", and an
# empty auto-filled title and body — both side effects of comparing unrelated branches.
#
# A script that ends at `git push` leaves the operator on that page. One that prints
# `gh pr create --base "$BR"` does not.
#
# NOTE ON THIS CHECK'S OWN IMPLEMENTATION: it reads each file WHOLE. The first version of
# this sweep grepped line by line and reported four scripts as unpinned that were fine —
# they write `gh pr create --repo ... \` with `--base "$B"` on the continuation line. A
# line-based grep is a proxy for "does this script pin the base"; the file is the property.
set -uo pipefail
cd "$(dirname "$0")/.."
findings=0

echo "== lint-pr-base-pinned"

for f in scripts/pr-*.sh; do
  [ -f "$f" ] || continue
  grep -q 'git push' "$f" || continue

  if python3 - "$f" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
# gh pr create ... --base, allowing backslash-newline continuations between them.
sys.exit(0 if re.search(r'gh pr create(?:[^\n]|\\\n)*--base', s) else 1)
PY
  then continue; fi

  printf '  no base-pinned gh pr create: %s\n' "$f"
  findings=$((findings+1))
done

if [ "$findings" -eq 0 ]; then
  echo "  ok — every PR builder hands over an explicit base"
else
  echo
  echo "  Add after the push, where \$BR is the branch the topic was built FROM:"
  echo '      echo "   gh pr create --base $BR --head $TOPIC --fill"'
fi

exit $(( findings > 0 ))

#!/usr/bin/env bash
# PreToolUse(Bash) guard — blocks mutating commands against a protected target.
#
# PROTECTED is wired to this repo's confirmed production identifiers. With PROTECTED empty
# the guard is inert and blocks nothing; that is the safe default, not the configured state.
#
# Exit 0 = allow, exit 2 = block (stderr becomes the reason the agent sees).
set -uo pipefail

# ---- CONFIGURE ME -------------------------------------------------------------
MUTATING='(kubectl|\$K[A-Z]*)[^|;&]*[[:space:]](apply|delete|patch|replace|edit|scale|annotate|label|cordon|drain|taint|set[[:space:]]+(image|env|resources))|(kubectl|\$K[A-Z]*)[^|;&]*[[:space:]]rollout[[:space:]]+(restart|undo|pause|resume)|helm[[:space:]]+(install|upgrade|uninstall|rollback)|terraform[[:space:]]+(apply|destroy)|aws[[:space:]]+[a-z0-9-]+[[:space:]]+(delete|put|update|create)-'
# Confirmed prod: account 937464026810 = usxpress-prod (EKS, us-east-2), plus the on-prem
# prod cluster. Seven further account IDs appear in this repo and are NOT yet classified —
# add them here once their environment is confirmed.
PROTECTED='937464026810|usxpress-prod|op-usxpress-prod'
REASON='This command mutates a protected production target. Draft the change and the exact
commands, then promote it dev -> QA -> prod through Octopus. Never apply locally.'
# -------------------------------------------------------------------------------

[ -z "$PROTECTED" ] && exit 0    # unconfigured: never block

payload=$(cat)
# Strip heredoc BODIES: text being WRITTEN is data, not a command being RUN. Without this,
# writing a runbook that merely QUOTES a protected command blocks itself.
cmd=$(printf '%s' "$payload" | python3 -c '
import json, re, sys
c = json.load(sys.stdin).get("tool_input", {}).get("command", "")
out, lines, i = [], c.split("\n"), 0
while i < len(lines):
    line = lines[i]; out.append(line)
    m = re.search(r"<<-?\s*[\x27\"]?([A-Za-z_][A-Za-z0-9_]*)[\x27\"]?\s*$", line)
    i += 1
    if m:
        term = m.group(1)
        while i < len(lines) and lines[i].strip() != term:
            i += 1
        i += 1
print("\n".join(out))
' 2>/dev/null)
[ -z "$cmd" ] && exit 0

if printf '%s' "$cmd" | grep -qiE "$MUTATING" && printf '%s' "$cmd" | grep -qiE "$PROTECTED"; then
  { echo "BLOCKED by $(basename "$0") — mutating command against a protected target."; echo "$REASON"; } >&2
  exit 2
fi
exit 0

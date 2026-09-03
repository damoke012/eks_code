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
  # Compare by PREFIX: the recorded pin may be a short SHA while ls-remote returns all 40.
  # A literal != between the two forms never matches and reports "moved" forever.
  if [ -n "$head" ] && [ "${head#$pin}" = "$head" ] && [ "${pin#$head}" = "$pin" ]; then
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

section "6. Cluster checks worth running by hand"
# Not run here: they need a live cluster and a pinned --context, and this script
# is deliberately runnable anywhere. Listed so they are not forgotten -- every
# one of these caught a real defect that reported success at every other layer.
fence "scripts/check-service-ports-listening.sh <ns> --context <ctx>"
fence "   does anything listen where each Service routes? (INFRA-1654: eleven weeks)"
fence "scripts/check-onprem-route.sh <host> --context <ctx> [--tls-port N]"
fence "   route -> backend -> authoritative DNS vs local resolver -> HTTP/SNI (INFRA-1622)"
fence "scripts/check-postgres-secret-usable.sh"
fence "   authenticates, rather than comparing hashes (INFRA-1652: eight days)"
fence "scripts/check-foreign-cluster-ids.sh <checkout> <branch> --diff <base>"
fence "   another cluster's account/DNS/IPs in a branch (nine instances by 2026-08-20)"
fence "scripts/check-argocd-repo-credentials.sh --context <ctx>"
fence "   does every Application have a credential matching its repoURL? (PR #100"
fence "   reverted ssh:// to https:// and broke delivery for 18h, all statuses green)"
fence "scripts/rw-fleet-licence-status.sh"
fence "   RisingWave pods + console licence on ALL THREE clusters, restarts and expiry"
fence "   included -- a crashlooping pod reads as Running, and a valid licence expires"
fence "scripts/audit-ecr-policies.sh --profile infra-common --region us-east-2 --summary"
fence "   who can push to the shared registry (INFRA-1655: 515 of 517)"

section "7. Board honesty"
# Every ticket filed by a script here sets a parent epic and never a sprint, so
# work gets done on tickets that are invisible on the board. On 2026-08-24 that
# was 17 of them, 8 already closed. Needs a token, so it is listed not run.
fence "scripts/find-sprintless-tickets.py --sprint <id> --stranded-only"
fence "   tickets worked in the last 14d that are not on the board (17 on 2026-08-24)"
fence "scripts/check-sprint-membership.py <sprint-id> INFRA-nnn ..."
fence "   asks the sprint for its members -- no JQL predicate on the multi-valued"
fence "   sprint field can answer 'is this issue in sprint N' reliably"

section "8. Prose handed to a shell as a double-quoted string"
# A PR body full of backticks becomes commands. See
# wip/tooling/FINDINGS-2026-08-24-pr-body-executed.md
bash scripts/lint-shell-prose.sh || true

section "9. Flux revision drift (on-prem)"
# A merged PR + a green source reconcile proves nothing about what is APPLIED.
# See wip/onprem-argocd/FINDINGS-2026-08-24-argocd-url-and-route.md
for c in op-dev op-qa op-prod; do
  bash scripts/flux-revision-drift.sh --cluster "$c" || true
done


section "10. Jira scripts that write without proving their token"
# A bad token reads as 404 "does not exist" / 400 "no such project" -- a permissions
# problem, not an auth one. See wip/tooling/FINDINGS-2026-09-03-jira-board-writes.md
bash scripts/lint-jira-preflight.sh || findings=$((findings+1))

section "11. PR builders that leave the base unpinned"
# iaac-talos-flux-platform is branch-per-cluster with default op-dev, so GitHub's
# compare page offers a prod change for merge into dev. Caught 2026-09-03.
bash scripts/lint-pr-base-pinned.sh || findings=$((findings+1))

section "12. Do the gates themselves still work?"
# A gate that cannot produce a pass is not a check, it is a constant. rw-prod-status gate 5
# shipped for weeks unable to return DONE, and reported 7 failures against a healthy
# namespace on 2026-09-03. This replays recorded kubectl output through it, both directions.
bash scripts/rw-prod-status.test.sh || findings=$((findings+1))
bash scripts/rw-fleet-licence-status.test.sh || findings=$((findings+1))

printf '\nweekly-maintenance: %s finding(s)\n' "$findings"

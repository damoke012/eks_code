#!/usr/bin/env bash
# Survey variant-inc/risingwave-pipeline. Run on WSL, against a clone made with CORP
# credentials -- never from the codespace (CLAUDE.md rule 10).
#
#   git clone https://github.com/variant-inc/risingwave-pipeline.git ~/repos/risingwave-pipeline
#   bash ~/eks_code/scripts/rw-pipeline-repo-survey.sh ~/repos/risingwave-pipeline
#
# Read-only. Never writes to the clone, never pushes.
#
# REDACTION: archive/ and the pre-INFRA-1637 history hold LIVE Confluent credentials as
# quoted literals. Every file printed here is filtered -- a quoted string on a line
# mentioning password/secret/username/key/token becomes <REDACTED n chars>. Unquoted
# `secret kafka_api_key` references pass through, because those are names, not values.

set -uo pipefail
REPO="${1:-}"
[ -n "$REPO" ] || { echo "usage: $0 <path-to-risingwave-pipeline-clone>" >&2; exit 2; }
[ -d "$REPO/.git" ] || { echo "!! $REPO is not a git clone" >&2; exit 2; }

ORIGIN=$(git -C "$REPO" remote get-url origin 2>/dev/null)
case "$ORIGIN" in
  *variant-inc/risingwave-pipeline*) ;;
  *) echo "!! origin is '$ORIGIN' -- expected variant-inc/risingwave-pipeline" >&2; exit 2 ;;
esac

# ---- the redactor. Everything printed goes through this.
red() {
python3 -c '
import sys, re
KEYS = re.compile(r"(password|secret|username|user|api[_.]?key|token|credential)", re.I)
QUOTED = re.compile(r"""(\x27)([^\x27\n]{12,})(\x27)""")
for line in sys.stdin:
    if KEYS.search(line):
        line = QUOTED.sub(lambda m: "\x27<REDACTED %d chars>\x27" % len(m.group(2)), line)
    sys.stdout.write(line)
'
}
show() {  # show <path-relative-to-repo>
  local f="$REPO/$1"
  echo; echo "───── $1 ─────"
  [ -f "$f" ] || { echo "  (absent)"; return; }
  red < "$f"
}

echo "############### 1. IDENTITY ###############"
echo "origin : $ORIGIN"
echo "branch : $(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
echo "HEAD   : $(git -C "$REPO" log -1 --format='%h %ad %an -- %s' --date=short)"
echo
echo "-- branches"
git -C "$REPO" branch -r | head -20
echo
echo "-- last 25 commits"
git -C "$REPO" log -25 --format='%h %ad %-18an %s' --date=short

echo
echo "############### 2. TREE ###############"
git -C "$REPO" ls-files | grep -v '^archive/' | sed 's|^|  |'
echo
echo "-- archive/ (kept separate: pre-fix copies live here)"
git -C "$REPO" ls-files 'archive/*' | sed 's|^|  |'

echo
echo "############### 3. THE APPLIER ###############"
show build/apply.sh
show build/Dockerfile

echo
echo "############### 4. %VAR% SUBSTITUTION -- THE OPEN QUESTION ###############"
echo "-- every %PLACEHOLDER% used anywhere in the repo:"
git -C "$REPO" grep -ohE '%[A-Z0-9_]+%' -- . 2>/dev/null | sort -u | sed 's|^|  |'
echo
echo "-- anything that could SUBSTITUTE them (envsubst / sed / \${VAR} expansion):"
git -C "$REPO" grep -nE 'envsubst|sed .*%|%[A-Z0-9_]+%' -- '*.sh' '*.yml' '*.yaml' 'Dockerfile*' 2>/dev/null \
  | grep -v '^pipelines/' | sed 's|^|  |' | head -40
echo
echo "  >> If nothing above rewrites %VAR%, the Argo CD sync-hook applier sends the literal"
echo "     placeholder to RisingWave, and INFRA-1635 is blocked until apply.sh grows a"
echo "     substitution step. That is the claim to confirm or kill here."

echo
echo "############### 5. WORKFLOWS ###############"
for f in $(git -C "$REPO" ls-files '.github/workflows/*'); do show "$f"; done

echo
echo "############### 6. DEPLOY (what Argo CD renders) ###############"
for f in $(git -C "$REPO" ls-files 'deploy/*'); do show "$f"; done

echo
echo "############### 7. PIPELINES -- what SQL exists ###############"
for d in $(git -C "$REPO" ls-files 'pipelines/*' | xargs -n1 dirname | sort -u); do
  echo; echo "  ── $d"
  for f in $(git -C "$REPO" ls-files "$d/*" | grep -E '\.(rw|sql)$'); do
    printf '     %-40s %s\n' "$(basename "$f")" "$(git -C "$REPO" log -1 --format='%ad %an' --date=short -- "$f")"
    grep -ohiE '^[[:space:]]*(CREATE|DROP|ALTER|INSERT|SELECT)[[:space:]]+[A-Z ]*[A-Za-z0-9_."]+' "$REPO/$f" \
      | sed 's/^[[:space:]]*//' | sed 's|^|         |'
    if grep -qiE "(sasl|schema\.registry)\.(username|password)[[:space:]]*=[[:space:]]*'" "$REPO/$f"; then
      echo "         ⚠️  QUOTED CREDENTIAL LITERAL in this file"
    fi
  done
done

echo
echo "############### 8. PLAINTEXT SWEEP (booleans only) ###############"
echo "-- tracked files where a credential key is followed by a quoted literal:"
git -C "$REPO" grep -lE "(sasl|schema\.registry)\.(username|password)[[:space:]]*=[[:space:]]*'" -- . 2>/dev/null \
  | sed 's|^|  ⚠️  |' || echo "  none in the working tree"
echo
echo "-- and in HISTORY (a fix commit does not unpublish what was pushed):"
git -C "$REPO" log --oneline -S"properties.sasl.password = '" --all 2>/dev/null | sed 's|^|  |' | head -10
echo "  >> Any commit listed above still contains the literal. If the key was rotated but not"
echo "     REVOKED, it is live and readable to anyone with repo access. That is INFRA-1637's"
echo "     second half."

echo
echo "############### 9. DOCS ###############"
for f in $(git -C "$REPO" ls-files '*.md' | grep -v '^archive/'); do
  printf '  %-42s %5s lines  %s\n' "$f" "$(wc -l < "$REPO/$f")" \
    "$(git -C "$REPO" log -1 --format='%ad %an' --date=short -- "$f")"
done
show SECRET_MANAGEMENT.md

echo
echo "############### 10. docker/ ###############"
for f in $(git -C "$REPO" ls-files 'docker/*'); do show "$f"; done

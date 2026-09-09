#!/usr/bin/env bash
# Sweep every pipeline file on a ref for literal credentials.
#
# READ ONLY, and it NEVER prints a value. Every quoted string is replaced before display,
# so the output is safe to paste into a ticket or a chat. That is the point: a scan you
# cannot show anyone is a scan nobody acts on.
#
# Written 2026-09-09 for INFRA-1690 AC5. INFRA-1637 converted Confluent credentials to
# RisingWave SECRET references and was read as "the files are clean". Two files were
# checked out of twenty-four, and the postgres-cdc block in employee/100-Sources.rw --
# sitting directly beneath converted Kafka properties in the same file -- still held a
# literal password. One sample is not a population (CLAUDE.md rule 5).
#
# Three verdicts per line:
#   ok          `= secret <name>`   a RisingWave SECRET object reference
#   ok          `= '%VAR%'`         a placeholder apply.sh renders at run time
#   LITERAL     anything else       a value committed to the repository
#
#   bash scripts/scan-pipeline-plaintext.sh                      # origin/master
#   bash scripts/scan-pipeline-plaintext.sh --ref origin/master --repo ~/repos/risingwave-pipeline
set -uo pipefail

REPO="${REPO:-$HOME/repos/risingwave-pipeline}"
REF="origin/master"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --ref)  REF="$2";  shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -d "$REPO/.git" ] || { echo "!! not a git repo: $REPO" >&2; exit 2; }
cd "$REPO"
git rev-parse --verify -q "$REF" >/dev/null || { echo "!! no such ref: $REF" >&2; exit 2; }

# Property names worth looking at. `username` is included but reported separately -- a
# username is not a secret, and mixing the two is how a real finding gets lost in noise.
SECRET_RE='(password|passwd|secret|api[._]?key|api[._]?secret|token|credential|private[._]?key)'
USER_RE='(username|user)'

FILES=$(git ls-tree -r --name-only "$REF" -- pipelines | grep -E '\.(rw|sql)$' | sort)
N=$(printf '%s\n' "$FILES" | grep -c . || true)
echo "== scanning $N pipeline file(s) at $REF in $REPO"

LIT=0; OKREF=0; PLACE=0; USERS=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    num="${line%%:*}"; body="${line#*:}"
    case "$body" in
      *"= secret "*|*"=secret "*)
        OKREF=$((OKREF+1)); printf '   ok       %s:%s  %s\n' "$f" "$num" \
          "$(printf '%s' "$body" | sed -E 's/^[[:space:]]+//')" ;;
      *"'%"*"%'"*)
        PLACE=$((PLACE+1)); printf '   ok       %s:%s  %s\n' "$f" "$num" \
          "$(printf '%s' "$body" | sed -E "s/'%[A-Z0-9_]+%'/'<placeholder>'/g; s/^[[:space:]]+//")" ;;
      *"'"*)
        LIT=$((LIT+1)); printf '   LITERAL  %s:%s  %s\n' "$f" "$num" \
          "$(printf '%s' "$body" | sed -E "s/'[^']*'/'<REDACTED>'/g; s/^[[:space:]]+//")" ;;
    esac
  done < <(git show "$REF:$f" 2>/dev/null | grep -nEi "$SECRET_RE[[:space:]]*=" || true)

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "${line#*:}" in
      *"= secret "*|*"'%"*) : ;;
      *"'"*) USERS=$((USERS+1))
             printf '   info     %s:%s  %s\n' "$f" "${line%%:*}" \
               "$(printf '%s' "${line#*:}" | sed -E "s/'[^']*'/'<redacted>'/g; s/^[[:space:]]+//")" ;;
    esac
  done < <(git show "$REF:$f" 2>/dev/null | grep -nEi "^[[:space:]]*$USER_RE[[:space:]]*=" || true)
done <<< "$FILES"

echo
echo "== $OKREF secret reference(s), $PLACE placeholder(s), $USERS literal username(s), $LIT LITERAL secret(s)"
if [ "$LIT" -gt 0 ]; then
  echo "   A literal is a credential committed to the repository. Rotating it is not enough —"
  echo "   the old value has to be invalidated, or it stays usable from git history."
  exit 1
fi
echo "   No literal secrets on $REF."
exit 0

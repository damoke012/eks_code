#!/usr/bin/env bash
# Bounded triage of the open PRs on variant-inc/risingwave-pipeline.
#
# RUN ON WSL, against corp GHE. Output stays on the corp machine -- do not paste
# variant-inc source into a personal repo or a codespace (CLAUDE.md rule 10). Paste the
# SUMMARY freely; paste a diff only when it is small and you need a second pair of eyes.
#
# READ ONLY. It reads PRs; it never reviews, comments, approves or merges.
#
# Why bounded: PR #18 is 112 files and past sixty thousand lines under a title about one
# ARN. Dumping every diff produces something nobody reads, which is how a two-line change
# in a ConfigMap got merged unnoticed on 2026-09-02. Small PRs print in full; large ones
# print their file list and nothing else, so the size is visible instead of drowned.
#
#   bash scripts/rw-pr-triage.sh                 # summary of every open PR
#   bash scripts/rw-pr-triage.sh 17 20           # plus full diffs for those two
set -uo pipefail
REPO=variant-inc/risingwave-pipeline
MAX_LINES="${MAX_LINES:-400}"

command -v gh >/dev/null || { echo "!! gh not on PATH" >&2; exit 2; }
gh auth status >/dev/null 2>&1 || { echo "!! gh is not authenticated to corp GHE" >&2; exit 2; }

echo "== open PRs on $REPO"
gh pr list --repo "$REPO" --state open \
  --json number,title,author,reviewDecision,additions,deletions,changedFiles,baseRefName,headRefName \
  --jq '.[] | "#\(.number)\t\(.author.login)\t+\(.additions)/-\(.deletions) in \(.changedFiles)f\t\(.baseRefName)<-\(.headRefName)\t\(.reviewDecision // "no verdict")\t\(.title)"' \
  | column -t -s $'\t'

# Two open promotion PRs can be merged in the wrong order, and the older SHA then
# overwrites the newer one -- a silent rollback with two green merges behind it.
echo
echo "== promotion ordering"
PROMOS=$(gh pr list --repo "$REPO" --state open --json number,title,createdAt \
  --jq '.[] | select(.title | startswith("promote:")) | "\(.createdAt)\t#\(.number)\t\(.title)"' | sort)
if [ -z "$PROMOS" ]; then
  echo "   no open promotion PRs"
else
  printf '%s\n' "$PROMOS" | sed 's/^/   /'
  N=$(printf '%s\n' "$PROMOS" | grep -c . || true)
  if [ "$N" -gt 1 ]; then
    echo
    echo "   ⚠ $N open promotions against the same overlay."
    echo
    echo "   These are PARALLEL, not stacked: each replaces the SAME current digest, so"
    echo "   only one of them is wanted. Merging the older one deploys stale code, and"
    echo "   merging it AFTER the newer one is a rollback that reports success."
    echo
    echo "   Do NOT decide by PR date. A newer PR is not a newer commit -- that is the"
    echo "   proxy, and the property is ancestry. For each older source commit, check"
    echo "   it is actually contained in the newest before closing its PR:"
    echo
    NEWEST=$(printf '%s\n' "$PROMOS" | tail -1 | sed 's/.*promote: QA -> //')
    printf '%s\n' "$PROMOS" | head -n -1 | sed 's/.*promote: QA -> //' | while read -r old_sha; do
      [ -n "$old_sha" ] || continue
      echo "     git merge-base --is-ancestor $old_sha $NEWEST && echo CONTAINED || echo NOT-CONTAINED"
    done
    echo
    echo "   CONTAINED     -> close the older PR, merge the newest only."
    echo "   NOT-CONTAINED -> the branches diverged; closing it DROPS work. Rebuild"
    echo "                    from a commit that has both before promoting anything."
  fi
fi

# A digest belongs to a promotion PR. When any OTHER PR moves one, it is almost always a
# stale branch silently reverting a merged promotion -- #22 on 2026-09-08 put QA back on
# the 19 August image through a file nobody was reading, and it would have merged green.
echo
echo "== digest changes outside promotion PRs"
FOUND=0
while IFS=$'\t' read -r num title; do
  [ -n "$num" ] || continue
  case "$title" in "promote:"*) continue ;; esac
  d=$(gh pr diff "$num" --repo "$REPO" 2>/dev/null | grep -E '^[-+][[:space:]]*digest:[[:space:]]*sha256:' || true)
  [ -n "$d" ] || continue
  FOUND=1
  echo "   ⚠ #$num moves an image digest and is not a promotion:"
  printf '%s\n' "$d" | sed 's/^/       /'
  echo "     Check it against master before merging:"
  echo "       git diff origin/master pr-$num -- deploy/overlays"
  echo "     A branch cut before the last promotion reverts it just by touching the file."
done < <(gh pr list --repo "$REPO" --state open --json number,title --jq '.[] | "\(.number)\t\(.title)"')
[ "$FOUND" = "0" ] && echo "   none -- no open PR outside a promotion moves a digest"

for n in "$@"; do
  case "$n" in [0-9]*) ;; *) echo "!! '$n' is not a PR number" >&2; exit 2 ;; esac
  echo
  echo "=================== PR #$n ==================="
  gh pr view "$n" --repo "$REPO" \
    --json title,body,baseRefName,headRefName,additions,deletions,changedFiles,commits \
    --jq '"title: \(.title)
base:  \(.baseRefName) <- \(.headRefName)
size:  +\(.additions)/-\(.deletions) across \(.changedFiles) files
last commit: \(.commits[-1].committedDate // "unknown")  \(.commits[-1].messageHeadline // "")

--- body ---
\(.body // "(empty)")"'
  echo
  echo "--- files ---"
  gh pr diff "$n" --repo "$REPO" --name-only | sed 's/^/   /'
  LINES=$(gh pr diff "$n" --repo "$REPO" | wc -l | tr -d ' ')
  echo
  if [ "$LINES" -le "$MAX_LINES" ]; then
    echo "--- diff ($LINES lines) ---"
    gh pr diff "$n" --repo "$REPO"
  else
    echo "--- diff SUPPRESSED: $LINES lines, over MAX_LINES=$MAX_LINES ---"
    echo "    A PR this size cannot be reviewed by reading it end to end. Either ask for"
    echo "    it to be split, or review one path at a time:"
    echo "      gh pr diff $n --repo $REPO -- <path>"
  fi
done

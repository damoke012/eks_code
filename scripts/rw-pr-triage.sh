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
    echo "   ⚠ $N open promotions. Merge OLDEST FIRST (top of this list), or close the"
    echo "     superseded ones. Merging an older promote after a newer one rolls the"
    echo "     environment back, and both merges report success."
  fi
fi

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

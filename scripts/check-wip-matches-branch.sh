#!/usr/bin/env bash
# Does every draft under wip/ still match what the cluster branch actually ships?
#
# CLAUDE.md rule 7. wip/ holds drafts; the branch is truth. They drift, and the
# drift is invisible until someone builds a PR from the stale side. On 2026-08-20
# PR #100 copied wip/…/applicationset-qa.yaml over the op-qa branch and reverted
# an ApplicationSet's repoURL from ssh:// to https://, taking delivery down for
# 18 hours with every status field green.
#
# This does not enforce that wip == branch. Drafts for work not yet shipped SHOULD
# differ. It reports where they differ so the difference is a decision rather than
# an accident.
#
# READ ONLY.
#
#   scripts/check-wip-matches-branch.sh ~/pr-work/iaac-talos-flux-platform op-qa
#   scripts/check-wip-matches-branch.sh ~/pr-work/iaac-talos-flux-platform op-qa --show
set -uo pipefail

CHECKOUT="${1:-}"; BRANCH="${2:-}"; SHOW=0
[ "${3:-}" = "--show" ] && SHOW=1
[ -n "$CHECKOUT" ] && [ -n "$BRANCH" ] || {
  echo "usage: $0 <platform-checkout> <branch> [--show]" >&2; exit 2; }
[ -d "$CHECKOUT/.git" ] || { echo "!! $CHECKOUT is not a git checkout" >&2; exit 2; }

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
PACK="$REPO_ROOT/wip/onprem-app-cicd/platform"
[ -d "$PACK" ] || { echo "!! no pack at $PACK" >&2; exit 2; }

git -C "$CHECKOUT" fetch origin -q 2>/dev/null
git -C "$CHECKOUT" rev-parse --verify "origin/$BRANCH" >/dev/null 2>&1 \
  || { echo "!! origin/$BRANCH not found in $CHECKOUT" >&2; exit 1; }

BRANCH_FILES=$(git -C "$CHECKOUT" ls-tree -r --name-only "origin/$BRANCH" | grep '^infrastructure/')

echo "wip drafts vs origin/$BRANCH"
echo
SAME=0; DIFF=0; ABSENT=0
while IFS= read -r f; do
  BASE=$(basename "$f")
  # the pack keeps per-cluster dirs (argocd-config/op-qa); the branch does not
  MATCHES=$(printf '%s\n' "$BRANCH_FILES" | grep "/${BASE}$" || true)
  N=$(printf '%s\n' "$MATCHES" | grep -c . || true)

  if [ "$N" -eq 0 ]; then
    printf '  %-52s %s\n' "${f#$PACK/}" "not on this branch (draft, or another cluster's)"
    ABSENT=$((ABSENT + 1)); continue
  fi
  if [ "$N" -gt 1 ]; then
    printf '  %-52s %s\n' "${f#$PACK/}" "AMBIGUOUS — $N files share this name on the branch"
    continue
  fi
  if git -C "$CHECKOUT" show "origin/$BRANCH:$MATCHES" 2>/dev/null | diff -q - "$f" >/dev/null 2>&1; then
    printf '  %-52s %s\n' "${f#$PACK/}" "same as $MATCHES"
    SAME=$((SAME + 1))
  else
    printf '  %-52s %s\n' "${f#$PACK/}" "DIFFERS from $MATCHES"
    DIFF=$((DIFF + 1))
    if [ "$SHOW" = 1 ]; then
      git -C "$CHECKOUT" show "origin/$BRANCH:$MATCHES" 2>/dev/null \
        | diff -u - "$f" | sed 's/^/        /' | head -40
    fi
  fi
done < <(find "$PACK" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)

echo
printf '  %-14s %s\n' "identical"  "$SAME"
printf '  %-14s %s\n' "differing"  "$DIFF"
printf '  %-14s %s\n' "not shipped" "$ABSENT"
echo
if [ "$DIFF" -gt 0 ]; then
  echo "A DIFFERING file is not automatically wrong — it may be work in progress."
  echo "It IS wrong to build a PR from one without reading the diff. Re-run with"
  echo "--show, and never copy a pack file over the branch wholesale."
fi
exit 0

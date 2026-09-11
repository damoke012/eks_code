#!/usr/bin/env bash
# Point QA's PIPELINE_DIR at the canary directory so the canary runs ALONE.
# Needed because Brand/100-sources.rw is still selected and aborts the whole run on its
# missing %KAFKA_...% values before any file is applied.
# Reversible: scripts/canary-pipeline-dir-pr.sh --revert puts it back.
set -uo pipefail
REPO="variant-inc/risingwave-pipeline"
MODE="${1:-set}"
case "$MODE" in
  set)    FROM="/pipeline/pipelines"; TO="/pipeline/pipelines/canary"; BR="canary/pipeline-dir-2026-09-11" ;;
  --revert) FROM="/pipeline/pipelines/canary"; TO="/pipeline/pipelines"; BR="canary/pipeline-dir-revert-2026-09-11" ;;
  *) echo "usage: canary-pipeline-dir-pr.sh [--revert]"; exit 2 ;;
esac
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

gh repo clone "$REPO" "$T/rp" -- --quiet 2>/dev/null || { echo "clone failed"; exit 3; }
cd "$T/rp"
git checkout --quiet -b "$BR" origin/master
F="deploy/overlays/qa/endpoints.yaml"

CUR="$(grep -E '^\s+PIPELINE_DIR:' "$F" | awk '{print $2}')"
echo "current PIPELINE_DIR : $CUR"
if [ "$CUR" != "$FROM" ]; then
  echo "REFUSING: expected '$FROM' before changing it to '$TO'."
  echo "          Someone else has moved it; look before overwriting."; exit 4
fi
sed -i "s|^\(\s*PIPELINE_DIR:\s*\)$FROM\s*$|\1$TO|" "$F"
echo "new PIPELINE_DIR     : $(grep -E '^\s+PIPELINE_DIR:' "$F" | awk '{print $2}')"
echo

# the canary must exist in the image that QA is about to run
if [ "$MODE" = "set" ] && [ ! -f pipelines/canary/001-promotion-canary.rw ]; then
  echo "REFUSING: pipelines/canary/ is not on master yet -- PIPELINE_DIR would point at"
  echo "          nothing and apply.sh would exit 1. Merge the canary PR first."; exit 4
fi

echo "=== diff ==="
git --no-pager diff
echo
read -r -p "push and open the PR? [y/N] " a
case "$a" in y|Y|yes|YES) ;; *) echo "Not pushed."; exit 0 ;; esac

git add "$F"
if [ "$MODE" = "set" ]; then
  git commit -q -m "test: point QA PIPELINE_DIR at the canary directory

Runs the promotion canary alone. Brand/100-sources.rw is still selected under
/pipeline/pipelines and aborts the run on its missing %KAFKA_...% values before
any file is applied, so the canary never gets a chance. Reverted once green."
  TITLE="test: run the promotion canary alone on QA"
  BODY="Points QA's \`PIPELINE_DIR\` at \`/pipeline/pipelines/canary\` so the canary applies without \`Brand/100-sources.rw\` aborting the run first.

Reverted as soon as the canary proves the path. The Brand cutover scope in \`CUTOVER_SCOPE.md\` is unchanged — this only moves where the Job looks, temporarily.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
else
  git commit -q -m "test: point QA PIPELINE_DIR back at the full pipelines directory

The promotion canary proved the delivery path; restoring the Brand cutover scope."
  TITLE="test: restore QA PIPELINE_DIR after the canary"
  BODY="Puts \`PIPELINE_DIR\` back to \`/pipeline/pipelines\`. The canary proved the path end to end; the Brand cutover scope is restored and the canary file can now be removed.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
fi
git push -q origin "$BR"
printf '%s' "$BODY" > "$T/body.md"
gh pr create --repo "$REPO" --base master --head "$BR" --title "$TITLE" --body-file "$T/body.md"

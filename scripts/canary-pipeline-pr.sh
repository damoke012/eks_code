#!/usr/bin/env bash
# Open the promotion-canary PR on variant-inc/risingwave-pipeline.
# Clones to a temp dir, adds one file, pushes a branch, opens the PR. Asks first.
set -uo pipefail
REPO="variant-inc/risingwave-pipeline"
BRANCH="canary/promotion-path-2026-09-11"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../wip/rw-etl-promotion/canary"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

[ -f "$SRC/001-promotion-canary.rw" ] || { echo "canary file missing at $SRC"; exit 3; }
[ -f "$SRC/PR-BODY.md" ]              || { echo "PR body missing at $SRC"; exit 3; }

gh repo clone "$REPO" "$T/rp" -- --quiet 2>/dev/null || { echo "clone failed"; exit 3; }
cd "$T/rp"
git checkout --quiet -b "$BRANCH" origin/master

mkdir -p pipelines/canary
cp "$SRC/001-promotion-canary.rw" pipelines/canary/001-promotion-canary.rw

echo "=== the file being added ==="
cat pipelines/canary/001-promotion-canary.rw
echo
echo "=== would the QA overlay's EXCLUDE_RE skip it? ==="
ERE="$(grep -E "^\s+EXCLUDE_RE:" deploy/overlays/qa/endpoints.yaml | sed "s/^[^']*'//; s/'\s*$//")"
echo "  EXCLUDE_RE = $ERE"
if printf '%s\n' "pipelines/canary/001-promotion-canary.rw" | grep -qE "$ERE"; then
  echo "  EXCLUDED -- the canary would never run. Stopping."; exit 4
fi
echo "  selected -- good"
echo
echo "=== files this branch changes vs master ==="
git add pipelines/canary/001-promotion-canary.rw
git --no-pager diff --cached --stat
echo
read -r -p "push branch and open the PR? [y/N] " a
case "$a" in y|Y|yes|YES) ;; *) echo "Not pushed."; exit 0 ;; esac

git commit -q -m "test: add a self-contained promotion canary

Proves commit -> build -> promotion -> Argo -> apply.sh -> RisingWave with a
file that depends on nothing outside RisingWave. Temporary; remove once the
path is proven."
git push -q origin "$BRANCH"
gh pr create --repo "$REPO" --base master --head "$BRANCH" \
  --title "test: promotion canary -- prove the delivery path without Kafka or the app database" \
  --body-file "$SRC/PR-BODY.md"

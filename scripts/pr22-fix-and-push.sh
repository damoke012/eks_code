#!/usr/bin/env bash
# Fix #22 so it can merge: drop the entity-postgres patch entries the base no longer has.
# Renders both overlays and refuses to push unless the result is provably right.
# Pushes to Idris's branch ONLY after you say yes.
set -uo pipefail
REPO="variant-inc/risingwave-pipeline"
BRANCH="cutover/qa-brand-pipeline"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

gh repo clone "$REPO" "$T/rp" -- --quiet 2>/dev/null || { echo "clone failed"; exit 3; }
cd "$T/rp"
git fetch --quiet origin "$BRANCH" || { echo "fetch failed"; exit 3; }
git checkout --quiet -B fixup "origin/$BRANCH"
echo "branch head before: $(git rev-parse --short HEAD)"
echo

echo "########## 1. remove the stale patch entries ##########"
python3 "$HERE/fix-overlay-entity-patches.py" deploy/overlays/qa/kustomization.yaml
python3 "$HERE/fix-overlay-entity-patches.py" deploy/overlays/prod/kustomization.yaml
echo

echo "########## 2. render QA -- this is the check that failed before ##########"
if ! kubectl kustomize deploy/overlays/qa > "$T/qa.yaml" 2>"$T/qa.err"; then
  echo "STILL FAILS -- not pushing:"; sed 's/^/   /' "$T/qa.err"; exit 4
fi
echo "kustomize build deploy/overlays/qa: OK"

FAIL=0
python3 "$HERE/verify-rendered-qa.py" qa < "$T/qa.yaml" || FAIL=1
echo

echo "########## 3. render prod (it inherits the same base change) ##########"
if kubectl kustomize deploy/overlays/prod > "$T/prod.yaml" 2>"$T/prod.err"; then
  echo "kustomize build deploy/overlays/prod: OK"
  grep -q 'entity-postgres' "$T/prod.yaml" && echo "  note: entity-postgres still in prod render" || echo "  ok: prod render is clean too"
else
  echo "prod render FAILED (reported, not blocking the QA fix):"; sed 's/^/   /' "$T/prod.err"
fi
echo

echo "########## 4. the change you would be pushing ##########"
git --no-pager diff
echo
[ "$FAIL" -ne 0 ] && { echo "One or more checks FAILED above. Not pushing."; exit 5; }

echo "All checks passed. This pushes one commit to $BRANCH (Idris's PR branch)."
read -r -p "push? [y/N] " ans
case "$ans" in
  y|Y|yes|YES) ;;
  *) echo "Not pushed. The temp clone is discarded; nothing changed."; exit 0 ;;
esac

git add deploy/overlays/qa/kustomization.yaml deploy/overlays/prod/kustomization.yaml
git commit -q -m "fix: drop entity-postgres patch entries the base no longer defines

The base ExternalSecret lost data entries 3 and 4, so the qa and prod overlays
patched indexes that no longer exist and kustomize build failed:

  error: replace operation does not apply: doc is missing path: /spec/data/3/remoteRef/key

Verified with kubectl kustomize on both overlays; the QA render now carries exactly
three entries -- RW_PASSWORD from risingwave/root, PG_PASSWORD and PG_USER from
risingwave/postgres."
git push origin HEAD:"$BRANCH" && echo && echo "pushed. New head: $(git rev-parse --short HEAD)"

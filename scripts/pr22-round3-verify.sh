#!/usr/bin/env bash
# Round 3 verification for variant-inc/risingwave-pipeline #22 (b04a394).
# Read-only: clones to a temp dir, reads op-qa. Changes nothing anywhere.
set -uo pipefail
REPO="variant-inc/risingwave-pipeline"
BRANCH="cutover/qa-brand-pipeline"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

echo "############ A. the EFFECTIVE diff (not the one GitHub displays) ############"
gh repo clone "$REPO" "$T/rp" -- --quiet 2>/dev/null || { echo "clone failed"; exit 3; }
git -C "$T/rp" fetch --quiet origin "$BRANCH:pr22" || { echo "fetch of $BRANCH failed"; exit 3; }
echo "head        : $(git -C "$T/rp" rev-parse --short pr22)"
echo "master      : $(git -C "$T/rp" rev-parse --short origin/master)"
if git -C "$T/rp" merge-base --is-ancestor origin/master pr22; then
  echo "rebased     : YES -- master is an ancestor, the branch is current"
else
  echo "rebased     : NO  -- branch does NOT contain current master; it can still revert files"
fi
echo
git -C "$T/rp" diff --stat origin/master pr22
echo
echo "############ B. does it still revert the QA digest? ############"
MD="$(git -C "$T/rp" show origin/master:deploy/overlays/qa/kustomization.yaml 2>/dev/null | grep -E 'digest:' || echo 'NO digest line on master')"
BD="$(git -C "$T/rp" show pr22:deploy/overlays/qa/kustomization.yaml 2>/dev/null | grep -E 'digest:' || echo 'NO digest line on branch')"
echo "  master : $MD"
echo "  branch : $BD"
if [ "$MD" = "$BD" ]; then echo "  VERDICT: same digest -- the Round 2 revert is gone"
else echo "  VERDICT: DIFFERENT -- read both before merging"; fi
echo
echo "############ C. are the entity-postgres refs actually gone? ############"
echo "-- every POSTGRES_ENTITY reference on the branch, by file:"
git -C "$T/rp" grep -n "POSTGRES_ENTITY\|entity-postgres" pr22 -- . 2>/dev/null | sed 's/^pr22://' || echo "  (none anywhere)"
echo
echo "-- specifically in what QA deploys (ExternalSecret + Job must both be clean):"
git -C "$T/rp" grep -ln "POSTGRES_ENTITY\|entity-postgres" pr22 -- deploy 2>/dev/null | sed 's/^pr22:/  STILL PRESENT: /' \
  || echo "  deploy/ is clean"
echo
echo "############ D. does an empty PIPELINE_DIR now fail? ############"
git -C "$T/rp" show pr22:build/apply.sh > "$T/apply.sh" 2>/dev/null || echo "  no build/apply.sh on branch"
grep -n -B4 -A8 "no .sql or .rw files\|ALLOW_EMPTY" "$T/apply.sh" 2>/dev/null || echo "  the empty-glob message is gone -- read apply.sh by hand"
echo
echo "############ E. Brand's tokens vs what QA can actually supply ############"
echo "-- %TOKENS% the two selected Brand files demand:"
for f in pipelines/Brand/100-sources.rw pipelines/Brand/200-ingest.rw; do
  echo "   $f"
  git -C "$T/rp" show "pr22:$f" 2>/dev/null | grep -oE '%[A-Z][A-Z0-9_]*%' | sort -u | sed 's/^/      /' \
    || echo "      (file not found on branch)"
done
echo
echo "-- keys the QA ConfigMap supplies (addresses, safe to print):"
R="$(python3 "$(dirname "${BASH_SOURCE[0]}")/kube-resolve-onprem.py" qa)" || { echo "   (no QA kubeconfig)"; R=""; }
if [ -n "$R" ]; then
  export KUBECONFIG="$(printf '%s' "$R" | cut -f1)"; CTX="$(printf '%s' "$R" | cut -f2)"
  kubectl --context "$CTX" -n app-risingwave get cm etl-pipeline-endpoints \
    -o go-template='{{range $k,$v := .data}}      {{$k}} = {{$v}}{{"\n"}}{{end}}' 2>/dev/null \
    || echo "      (ConfigMap not readable)"
  echo
  echo "-- keys the QA Secret supplies (NAMES only, no values):"
  kubectl --context "$CTX" -n app-risingwave get secret etl-pipeline-credentials \
    -o go-template='{{range $k,$v := .data}}      {{$k}}{{"\n"}}{{end}}' 2>/dev/null \
    || echo "      (Secret not readable)"
fi
echo
echo "Every token in E must appear in one of the two lists, or the run fails on first apply."

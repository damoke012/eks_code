#!/usr/bin/env bash
# Does this platform branch name another cluster? Run it BEFORE the PR.
#
# INFRA-1646. The op-dev / op-qa / op-prod branches of iaac-talos-flux-platform are
# copies of one another rather than per-cluster configurations, so cluster-specific
# values routinely stay pointed at the source cluster. The failure is always
# silent: the Flux Kustomization reports Ready while the workload cannot
# authenticate or route.
#
# Six instances by 2026-08-20 — dev's IRSA role ARN on all three branches;
# ecr-credentials never wired on QA or prod; op-qa RisingWave routes carrying
# op-dev hostnames and dev node addresses; those routes binding to a Gateway that
# does not exist on QA; a dev postgres service name in the QA app overlay; and
# `main` as targetRevision where the repo's default branch is `master`.
#
# The shared ECR account 064859874041 is deliberately NOT flagged — every cluster
# pulls from it, so naming it is correct.
#
# Usage:
#   ./check-foreign-cluster-ids.sh <dir> <op-dev|op-qa|op-prod> [--diff <base-ref>]
#
#   ./check-foreign-cluster-ids.sh ~/iaac-talos-flux-platform op-qa
#   ./check-foreign-cluster-ids.sh ~/iaac-talos-flux-platform op-qa --diff origin/op-qa
#
# --diff limits the scan to files changed against <base-ref>, which is what you
# want in a pre-merge hook; without it the whole tree is scanned, which is what
# you want before wiring a directory onto a new cluster.
set -uo pipefail

DIR="${1:?usage: $0 <dir> <op-dev|op-qa|op-prod> [--diff <base-ref>]}"
TARGET="${2:?usage: $0 <dir> <op-dev|op-qa|op-prod> [--diff <base-ref>]}"
BASE=""
[[ "${3:-}" == "--diff" ]] && BASE="${4:?--diff needs a base ref}"

# name|account|oidc-issuer|api-node|dns-suffix
IDS_op_dev="op-usxpress-dev|700736442855|d3a7wcnazdrd6p|10.10.82.50|op-dev.usxpress.io"
IDS_op_qa="op-usxpress-qa|527101283767|d2t7d36wmf0hbm|10.10.82.51|op-qa.usxpress.io"
IDS_op_prod="op-usxpress-prod|937464026810|d3rxit8f4yvshu|10.10.82.52|op-prod.usxpress.io"

case "$TARGET" in
  op-dev)  FOREIGN="$IDS_op_qa|$IDS_op_prod" ;;
  op-qa)   FOREIGN="$IDS_op_dev|$IDS_op_prod" ;;
  op-prod) FOREIGN="$IDS_op_dev|$IDS_op_qa" ;;
  *) echo "unknown target '$TARGET' (want op-dev, op-qa or op-prod)"; exit 2 ;;
esac

cd "$DIR" || { echo "no such directory: $DIR"; exit 2; }

if [[ -n "$BASE" ]]; then
  mapfile -t FILES < <(git diff --name-only --diff-filter=ACMR "$BASE" -- . 2>/dev/null)
  echo "scanning ${#FILES[@]} file(s) changed against $BASE, for identifiers that do not belong to $TARGET"
else
  mapfile -t FILES < <(git ls-files 2>/dev/null || find . -type f)
  echo "scanning ${#FILES[@]} tracked file(s), for identifiers that do not belong to $TARGET"
fi
(( ${#FILES[@]} )) || { echo "  nothing to scan"; exit 0; }
echo

hits=0
for id in ${FOREIGN//|/ }; do
  out=$(grep -RIn --fixed-strings -- "$id" "${FILES[@]}" 2>/dev/null \
        | grep -v '^\s*#' | grep -vi 'superseded\|previously\|was wrong\|not this' || true)
  if [[ -n "$out" ]]; then
    printf '  ✗ %s\n' "$id"
    printf '%s\n' "$out" | sed 's/^/      /'
    hits=$((hits + 1))
  fi
done

if (( hits )); then
  echo
  echo "  $hits foreign identifier(s) on a branch for $TARGET."
  echo "  Each one is a workload that will report Ready and then fail to authenticate"
  echo "  or route. Fix before merging."
  exit 1
fi
echo "  clean — no identifier belonging to another cluster"

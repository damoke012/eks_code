#!/usr/bin/env bash
# pr-touches-ns.sh — given a Flux source repo + path, print every namespace it manages.
#
# Used during PR review (Phase 2 — Tim coord gate) to determine whether a PR
# targets Tim's `risingwave` ns (needs Tim coord) or some other ns. Never trust
# the PR description on this — the source manifests are the source of truth.
#
# Usage:
#   ./scripts/pr-touches-ns.sh <repo-url> <branch> <manifests-path>
#
# Examples:
#   ./scripts/pr-touches-ns.sh variant-inc/iaac-risingwave-onprem main manifests/op-usxpress-dev
#   ./scripts/pr-touches-ns.sh variant-inc/iaac-risingwave-2 main manifests
#
# Works in codespace (only needs gh + git, no cluster reach).

set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: $0 <repo-org/repo> <branch> <manifests-path>" >&2
  echo "example: $0 variant-inc/iaac-risingwave-onprem main manifests/op-usxpress-dev" >&2
  exit 2
fi

REPO="$1"
BRANCH="$2"
PATH_IN_REPO="$3"

REPO_NAME="${REPO##*/}"
WORKDIR="/tmp/pr-touches-ns-${REPO_NAME}"

echo "== pr-touches-ns.sh — repo=$REPO branch=$BRANCH path=$PATH_IN_REPO =="
echo ""

# Fresh clone (we want the current state of the branch, not a cached one)
rm -rf "$WORKDIR"
echo "Cloning $REPO@$BRANCH..."
gh repo clone "$REPO" "$WORKDIR" -- --depth 1 --branch "$BRANCH" >/dev/null

if [[ ! -d "$WORKDIR/$PATH_IN_REPO" ]]; then
  echo "ERROR: path $PATH_IN_REPO does not exist in $REPO@$BRANCH" >&2
  exit 1
fi

cd "$WORKDIR/$PATH_IN_REPO"

echo ""
echo "=== 1. Namespaces defined in this path (Namespace kind manifests) ==="
grep -lE "^\s*kind:\s*Namespace\s*$" *.yaml 2>/dev/null | while read -r f; do
  name=$(grep -A 3 "^kind: Namespace" "$f" | grep -E "^\s*name:" | head -1 | awk '{print $2}')
  echo "  $f -> Namespace/$name"
done || echo "  (none — manifests target an existing ns)"

echo ""
echo "=== 2. All distinct 'namespace:' references in this path ==="
grep -hE "^\s*namespace:" *.yaml 2>/dev/null | awk '{print $2}' | sort -u | sed 's/^/  /' || echo "  (none)"

echo ""
echo "=== 3. Kustomization namespace (if any) ==="
if [[ -f kustomization.yaml ]]; then
  grep -E "^namespace:" kustomization.yaml | sed 's/^/  /' || echo "  (kustomization.yaml has no top-level namespace:)"
else
  echo "  (no kustomization.yaml at path root)"
fi

echo ""
echo "=== 4. Files in path ==="
ls -1 | sed 's/^/  /'

echo ""
echo "=== Tim coord rule ==="
TARGETS=$(grep -hE "^\s*namespace:" *.yaml 2>/dev/null | awk '{print $2}' | sort -u | tr '\n' ' ')
if echo "$TARGETS" | grep -qw "risingwave"; then
  echo "  ⚠️  TARGETS INCLUDE 'risingwave' (Tim's ns) — Tim coord IS REQUIRED before merge."
fi
if echo "$TARGETS" | grep -qw "risingwave-2"; then
  echo "  ℹ️  Targets include 'risingwave-2' (Doke's IaC pattern) — Tim coord NOT required for this ns."
fi
if ! echo "$TARGETS" | grep -qwE "risingwave|risingwave-2"; then
  echo "  ℹ️  No risingwave* ns in this path. Tim coord likely not required (but check cluster-wide impact)."
fi

echo ""
echo "Cleanup: $WORKDIR (delete when done)"

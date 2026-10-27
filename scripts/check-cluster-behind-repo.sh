#!/usr/bin/env bash
# Is a cluster running an older tag than its source repo has published?
# READ ONLY -- it reads Flux objects and queries git remotes. Nothing is written.
#
#   scripts/check-cluster-behind-repo.sh dev|qa|prod
#   scripts/check-cluster-behind-repo.sh prod --verbose
#
# WHY THIS EXISTS
#   On 2026-10-27 op-usxpress-prod ran iaac-risingwave-onprem v0.11.3, tagged
#   2026-10-13. The repo was at v0.13.3. SIX commits had been merged, CI had
#   passed on each, tags had been cut -- and not one of them was on any
#   cluster. Every Flux object was green, because a green Kustomization means
#   THE PINNED REVISION applied cleanly, not that your change is there.
#
#   Delivery to prod is four steps and three are invisible from the PR:
#     merge to main -> a tag is cut -> SOMEONE EDITS THE PIN -> Flux reconciles
#   The third has no automation and nothing reports when it has not happened.
#   This is that report.
#
# It does NOT say a cluster SHOULD be on the newest tag. Pinning is the
# promotion gate and being behind is often correct. It says how far behind,
# so the gap is a decision rather than a surprise.
set -uo pipefail

ENV="${1:-}"
VERBOSE=no; [ "${2:-}" = "--verbose" ] && VERBOSE=yes
case "$ENV" in
  dev)  EP=10.10.82.50 ;;
  qa)   EP=10.10.82.51 ;;
  prod) EP=10.10.82.52 ;;
  *) echo "usage: $0 dev|qa|prod [--verbose]"; exit 2 ;;
esac

say() { printf '%s\n' "$*"; }

# Resolve by which kubeconfig ANSWERS, never by filename: ~/.kube on the WSL box
# holds op-usxpress-dev.yaml pointing at a CLOUD EKS cluster.
KC=""
for f in "$HOME"/.kube/*.yaml "$HOME"/.kube/*.yml; do
  [ -f "$f" ] || continue
  S=$(kubectl --kubeconfig="$f" config view -o jsonpath='{.clusters[*].cluster.server}' 2>/dev/null)
  [ "$(echo "$S" | wc -w)" = "1" ] || continue
  case "$S" in *"$EP:6443"*) ;; *) continue ;; esac
  kubectl --kubeconfig="$f" get --raw /version >/dev/null 2>&1 && { KC="$f"; break; }
done
if [ -z "$KC" ]; then
  say "NOT MEASURED - no working kubeconfig answers $EP:6443."
  say "   Check the VPN before reading this as a fact about the cluster:"
  say "     bash -c 'echo > /dev/tcp/$EP/6443'"
  exit 3
fi
say "== op-usxpress-$ENV   via $(basename "$KC")"
say ""

ROWS=$(kubectl --kubeconfig="$KC" -n flux-system get gitrepository \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.url}{"\t"}{.spec.ref.tag}{"\t"}{.spec.ref.branch}{"\t"}{.status.artifact.revision}{"\n"}{end}' 2>/dev/null)
[ -n "$ROWS" ] || { say "NOT MEASURED - no GitRepository objects readable in flux-system"; exit 3; }

BEHIND=0; PINNED=0; TRACKING=0; UNKNOWN=0

# highest_tag prints the greatest semver tag a remote publishes, or nothing.
# `sort -V` rather than lexical: v0.9.0 is NOT newer than v0.13.0, and a lexical
# sort says it is. That single mistake would invert every verdict here.
highest_tag() {
  git ls-remote --tags "$1" 2>/dev/null \
    | sed 's#.*refs/tags/##' | grep -v '\^{}$' \
    | grep -E '^v?[0-9]+\.[0-9]+(\.[0-9]+)?$' \
    | sort -V | tail -1
}

printf '%s\n' "$ROWS" | while IFS=$'\t' read -r NAME URL TAG BRANCH REV; do
  [ -n "$NAME" ] || continue
  if [ -n "$BRANCH" ]; then
    TRACKING=$((TRACKING+1))
    say "  $NAME"
    say "      branch $BRANCH -- tracks the tip, nothing to compare"
    [ "$VERBOSE" = yes ] && say "      at: $REV"
    continue
  fi
  if [ -z "$TAG" ]; then
    UNKNOWN=$((UNKNOWN+1))
    say "  $NAME"
    say "      ${YELLOW:-}neither tag nor branch in .spec.ref -- read it by hand${RESET:-}"
    continue
  fi
  PINNED=$((PINNED+1))
  LATEST=$(highest_tag "$URL")
  if [ -z "$LATEST" ]; then
    say "  $NAME"
    say "      pinned $TAG -- could NOT read tags from the remote."
    say "      That is an access answer, not 'no newer version'. Not measured."
    continue
  fi
  if [ "$TAG" = "$LATEST" ]; then
    say "  $NAME"
    say "      pinned $TAG = latest published. Current."
  else
    # Only call it behind if the latest actually sorts ABOVE the pin. A pin
    # AHEAD of the newest published tag is a different fault worth seeing.
    NEWER=$(printf '%s\n%s\n' "$TAG" "$LATEST" | sort -V | tail -1)
    if [ "$NEWER" = "$TAG" ]; then
      say "  $NAME"
      say "      pinned $TAG but the newest published is $LATEST -- the pin is AHEAD."
      say "      A tag was deleted, or the pin names something that was never published."
    else
      BEHIND=$((BEHIND+1))
      say "  $NAME"
      say "      ${RED:-}BEHIND${RESET:-}  pinned $TAG  ->  published $LATEST"
      say "      Nothing merged since $TAG is on this cluster."
      say "      Promote by editing .spec.ref.tag for this cluster, then open a PR."
    fi
  fi
  [ "$VERBOSE" = yes ] && say "      url: $URL"
done

say ""
say "A pinned source being behind is not automatically wrong -- the pin IS the"
say "promotion gate. It is wrong when nobody knows. Compare this against what"
say "the team intends to be running, and promote deliberately."
say ""
say "The pins for this cluster live in iaac-talos-flux-cluster, branch master:"
say "    clusters/op-usxpress-$ENV/flux-system/infra.yaml"
say "Precedent PR: 'INFRA-1647: promote iaac-risingwave-onprem v0.11.3 to"
say "op-usxpress-prod (#48)' -- follow that shape."

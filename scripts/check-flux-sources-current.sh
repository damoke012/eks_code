#!/usr/bin/env bash
# Is each Flux GitRepository actually holding the remote's current commit?
#
# INFRA-1642. Flux reports Ready=True for a source it fetched successfully, and
# keeps serving its last good artifact if fetching later starts failing in a way
# that does not flip the condition. `.status.artifact.lastUpdateTime` does NOT
# answer this: it is the last time the REVISION CHANGED, so a correctly-pinned
# tag or a repo with no new commits looks identical to one that stopped fetching.
#
# The only test that settles it is comparing the held revision against the remote
# ref. That is what this does — one `git ls-remote` per source.
#
# READ ONLY.
#
#   scripts/check-flux-sources-current.sh --context op-usxpress-qa-sso
#   scripts/check-flux-sources-current.sh --context op-usxpress-qa-sso \
#       --kubeconfig ~/.kube/op-usxpress-qa-sso.yaml
#
# Private repos need credentials git can use. Where it cannot read a remote it
# says UNKNOWN — it never reports "current" for something it could not check.
set -uo pipefail

CTX=""; KCFG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --context)    CTX="$2";  shift 2 ;;
    --kubeconfig) KCFG="$2"; shift 2 ;;
    -h|--help)    sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$CTX" ] || { echo "usage: $0 --context <ctx> [--kubeconfig P]" >&2; exit 2; }

k() { kubectl ${KCFG:+--kubeconfig="$KCFG"} --context "$CTX" "$@"; }
command -v jq >/dev/null || { echo "!! jq not installed" >&2; exit 2; }

echo "GitRepository sources on $CTX"
echo
printf '%-38s %-26s %-10s %s\n' NAME REF HELD STATE
printf '%-38s %-26s %-10s %s\n' "----" "---" "----" "-----"

FAIL=0
while IFS=$'\t' read -r NAME URL BRANCH TAG SEMVER COMMIT HELD READY; do
  REF="${BRANCH:-}"; KIND=branch
  [ -n "${TAG:-}"    ] && { REF="$TAG";    KIND=tag; }
  [ -n "${SEMVER:-}" ] && { REF="$SEMVER"; KIND=semver; }
  [ -n "${COMMIT:-}" ] && { REF="$COMMIT"; KIND=commit; }
  [ -n "$REF" ] || { REF="master"; KIND=branch; }

  HELD_SHA="${HELD##*:}"; SHORT="${HELD_SHA:0:12}"

  if [ "$READY" != "True" ]; then
    printf '%-38s %-26s %-10s %s\n' "$NAME" "$REF" "$SHORT" "NOT READY — Flux says so itself"
    FAIL=1; continue
  fi

  case "$KIND" in
    commit) printf '%-38s %-26s %-10s %s\n' "$NAME" "$REF" "$SHORT" "pinned to a commit"; continue ;;
    semver) printf '%-38s %-26s %-10s %s\n' "$NAME" "$REF" "$SHORT" "semver range — not compared"; continue ;;
  esac

  REMOTE=$(timeout 25 git ls-remote "$URL" "$REF" 2>/dev/null | awk 'NR==1{print $1}')
  if [ -z "$REMOTE" ]; then
    printf '%-38s %-26s %-10s %s\n' "$NAME" "$REF" "$SHORT" "UNKNOWN — could not read the remote"
    continue
  fi

  if [ "$REMOTE" = "$HELD_SHA" ]; then
    printf '%-38s %-26s %-10s %s\n' "$NAME" "$REF" "$SHORT" "current"
  else
    printf '%-38s %-26s %-10s %s\n' "$NAME" "$REF" "$SHORT" "BEHIND — remote is ${REMOTE:0:12}"
    FAIL=1
  fi
done < <(k get gitrepository -A -o json | jq -r '
  .items[] | [
    .metadata.name, .spec.url,
    (.spec.ref.branch // ""), (.spec.ref.tag // ""), (.spec.ref.semver // ""), (.spec.ref.commit // ""),
    (.status.artifact.revision // ""),
    ((.status.conditions // [])[] | select(.type=="Ready") | .status) // "Unknown"
  ] | @tsv')

echo
if [ "$FAIL" = 0 ]; then
  echo "every comparable source holds the remote's current commit."
else
  echo "A 'BEHIND' source keeps reconciling its LAST GOOD artifact and reports Ready=True"
  echo "while doing it, so every Kustomization under it silently applies old state."
  echo "An 'UNKNOWN' is not a pass — it means this machine could not read that remote."
fi
exit "$FAIL"

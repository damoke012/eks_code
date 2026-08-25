#!/usr/bin/env bash
# Read what op-qa and op-prod actually have under infrastructure/argocd.
set -uo pipefail
cd "${REPO:-$HOME/pr-work/iaac-talos-flux-platform}" || exit 2
git fetch -q origin
for BR in op-qa op-prod; do
  printf '\n\033[1m########## %s ##########\033[0m\n' "$BR"
  if ! git rev-parse --verify -q "origin/$BR" >/dev/null; then
    echo "   no such branch"; continue; fi
  echo "--- files ---"
  git ls-tree --name-only "origin/$BR" infrastructure/argocd/ 2>/dev/null || echo "   (no infrastructure/argocd)"
  echo "--- kustomization resources ---"
  git show "origin/$BR:infrastructure/argocd/kustomization.yaml" 2>/dev/null | grep -A20 '^resources:' || echo "   (none)"
  echo "--- helmrelease: url / dex / oidc / rbac ---"
  git show "origin/$BR:infrastructure/argocd/helmrelease.yaml" 2>/dev/null \
    | grep -nE 'url:|dex:|enabled:|oidc\.config|dex\.config|policy\.csv|policy\.default|scopes:|g, |createSecret|configs:|  cm:|  secret:' \
    || echo "   (no helmrelease)"
  echo "--- ExternalSecret target + policy ---"
  for f in admin-externalsecret.yaml externalsecret.yaml; do
    git show "origin/$BR:infrastructure/argocd/$f" 2>/dev/null \
      | grep -nE 'kind:|name:|creationPolicy|key:|property:|secretKey' | sed "s|^|   $f: |"
  done
done

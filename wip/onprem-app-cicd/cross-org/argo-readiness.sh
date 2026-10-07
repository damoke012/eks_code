#!/usr/bin/env bash
# Can Argo CD actually deploy the RisingWave SQL pipeline image?
#
# READ ONLY. Every call is a get. Nothing is applied, patched or deleted.
#
# Five things have to be true before an Application will sync, and each fails
# differently. A missing one of these is why "merged" has looked like "deployed"
# before.
set -uo pipefail

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; OFF=$'\033[0m'
ok()   { printf '%sOK  %s%s\n' "$GRN" "$*" "$OFF"; }
gap()  { printf '%sGAP %s%s\n' "$RED" "$*" "$OFF"; }
warn() { printf '%s??  %s%s\n' "$YEL" "$*" "$OFF"; }

check() {
  local label="$1" kcfg="$2" ctx="$3" expect="$4"
  printf '\n============================================================\n'
  printf '##### %s #####\n' "$label"
  [ -r "$kcfg" ] || { warn "kubeconfig unreadable: $kcfg -- SKIPPED, nothing concluded"; return; }
  export KUBECONFIG="$kcfg"
  kubectl $ctx cluster-info 2>&1 | grep -q "$expect" \
    || { warn "endpoint $expect not found -- SKIPPED, nothing concluded"; return; }
  ok "reached $expect"

  echo; echo "-- 1. is Argo CD running? --"
  local n
  n=$(kubectl $ctx get pods -n argocd --no-headers 2>/dev/null | grep -c Running)
  [ "${n:-0}" -gt 0 ] && ok "$n argocd pods Running" || gap "no Argo CD pods in namespace argocd"

  echo; echo "-- 2. can it READ our git repos? (a credential, not a guess) --"
  kubectl $ctx get secret -n argocd -l argocd.argoproj.io/secret-type=repository \
    -o custom-columns='NAME:.metadata.name,URL:.data.url' --no-headers 2>/dev/null \
    | while read -r nm u; do printf '   %-40s %s\n' "$nm" "$(echo "$u" | base64 -d 2>/dev/null)"; done
  kubectl $ctx get secret -n argocd -l argocd.argoproj.io/secret-type=repository --no-headers 2>/dev/null | grep -q . \
    || gap "NO repository credentials -- every Application fails ComparisonError: authentication required"

  echo; echo "-- 3. existing Applications / ApplicationSets --"
  kubectl $ctx get applications,applicationsets -n argocd \
    -o custom-columns='KIND:.kind,NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
    --no-headers 2>/dev/null | sed 's/^/   /' | grep . || echo "   (none)"

  echo; echo "-- 4. target namespace and its ECR pull secret --"
  for ns in app-risingwave risingwave; do
    if kubectl $ctx get ns "$ns" >/dev/null 2>&1; then
      ok "namespace $ns exists"
      kubectl $ctx get secret -n "$ns" --no-headers 2>/dev/null \
        | grep -iE 'ecr|regcred|dockerconfig' | sed 's/^/     /' \
        || gap "$ns has NO ECR pull secret -- pods will ImagePullBackOff"
    else
      warn "namespace $ns absent"
    fi
  done

  echo; echo "-- 5. can the cluster reach the registry at all? --"
  kubectl $ctx get pods -A -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' 2>/dev/null \
    | grep -c '064859874041' | xargs -I{} echo "   pods already running images from 064859874041: {}"
  echo "   (zero means this cluster has never pulled from that registry -- unproven, not broken)"
}

check "op-usxpress-dev  (10.10.82.50)" "$HOME/.kube/op-usxpress-dev-fresh.yaml" ""                                 "10.10.82.50"
check "op-usxpress-qa   (10.10.82.51)" "$HOME/.kube/op-usxpress-qa.yaml"        "--context admin@op-usxpress-qa"   "10.10.82.51"

printf '\n============================================================\n'
echo "A skipped cluster proves nothing. Read the ?? lines before concluding."

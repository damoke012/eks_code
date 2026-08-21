#!/usr/bin/env bash
# How does this cluster reference its images -- by digest, or by a mutable tag?
#
# INFRA-1655 step (a). 515 of 517 repositories in the shared registry
# 064859874041 grant push to every account in org o-yza5l1xhrc, and 510 of them
# allow mutable tags. A workload that references a TAG in that registry therefore
# runs whatever was pushed last, by anyone in the organisation. A workload that
# references a DIGEST cannot be moved that way.
#
# On-prem is covered: require-image-digest is Enforce there (INFRA-1640). This
# answers the same question for a cloud cluster.
#
# STRICTLY READ ONLY. It lists and counts. It creates nothing, changes nothing,
# and runs no workload -- safe against a production cluster.
#
#   scripts/check-image-provenance.sh --context usxpress-prod --kubeconfig ~/.kube/qa-one-eks.yaml
set -uo pipefail

CTX=""; KCFG=""; SHARED="064859874041"
while [ $# -gt 0 ]; do
  case "$1" in
    --context)    CTX="$2";  shift 2 ;;
    --kubeconfig) KCFG="$2"; shift 2 ;;
    --registry)   SHARED="$2"; shift 2 ;;
    -h|--help)    sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$CTX" ] || { echo "usage: $0 --context <ctx> [--kubeconfig P]" >&2; exit 2; }

k() { kubectl ${KCFG:+--kubeconfig="$KCFG"} --context "$CTX" "$@"; }
command -v jq >/dev/null || { echo "!! jq not installed" >&2; exit 2; }

SRV=$(k config view -o jsonpath="{.clusters[?(@.name=='$(k config view -o jsonpath="{.contexts[?(@.name=='$CTX')].context.cluster}")')]}" 2>/dev/null)
echo "context $CTX"
k version -o json 2>/dev/null | jq -r '"server " + (.serverVersion.gitVersion // "unknown")' || {
  echo "!! cannot reach the cluster with context $CTX" >&2; exit 1; }

PODS=$(k get pods -A -o json 2>/dev/null)
[ -n "$PODS" ] || { echo "!! could not list pods (permissions?)" >&2; exit 1; }

# every container reference: init, regular and ephemeral
REFS=$(echo "$PODS" | jq -r '
  .items[] | .metadata.namespace as $ns |
  ((.spec.containers // []) + (.spec.initContainers // []) + (.spec.ephemeralContainers // []))[]
  | [$ns, .image] | @tsv')

TOTAL=$(printf '%s\n' "$REFS" | grep -c . || true)
DIGEST=$(printf '%s\n' "$REFS" | grep -c '@sha256:' || true)
TAG=$((TOTAL - DIGEST))

echo
echo "== how images are referenced (containers, including init and ephemeral)"
printf '  %-34s %s\n' "total references"       "$TOTAL"
printf '  %-34s %s\n' "pinned by digest"       "$DIGEST"
printf '  %-34s %s\n' "referenced by tag"      "$TAG"

echo
echo "== admission control that could require digests"
POL=$(k get clusterpolicy -o custom-columns=NAME:.metadata.name,ACTION:.spec.validationFailureAction --no-headers 2>/dev/null)
if [ -n "$POL" ]; then printf '%s\n' "$POL" | sed 's/^/  /'; else echo "  (no Kyverno ClusterPolicy CRD or none defined)"; fi
WH=$(k get validatingwebhookconfigurations -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null \
     | grep -iE 'kyverno|gatekeeper|policy|image|ratify|connaisseur' || true)
if [ -n "$WH" ]; then printf '%s\n' "$WH" | sed 's/^/  /'; else echo "  (no image-related validating webhook)"; fi

echo
echo "== the exposed set: images from the SHARED registry $SHARED referenced by TAG"
EXPOSED=$(printf '%s\n' "$REFS" | grep "$SHARED" | grep -v '@sha256:' || true)
if [ -z "$EXPOSED" ]; then
  echo "  none — no workload here can be moved by a push to that registry"
else
  printf '%s\n' "$EXPOSED" | awk -F'\t' '{printf "  %-26s %s\n", $1, $2}' | sort -u
  N=$(printf '%s\n' "$EXPOSED" | grep -c . || true)
  echo
  echo "  $N reference(s). Each runs whatever was last pushed to that tag, by any"
  echo "  principal in org o-yza5l1xhrc. Verify against the repository's own policy"
  echo "  before concluding severity: scripts/audit-ecr-policies.sh --profile infra-common"
fi

echo
echo "== other registries in use (context for where else images come from)"
printf '%s\n' "$REFS" | awk -F'\t' '{print $2}' | sed 's#/.*##' | sort | uniq -c | sort -rn | sed 's/^/  /'

#!/usr/bin/env bash
# Is the RisingWave pipeline like-for-like between op-dev and op-qa?
#
# Two things get conflated and they are not the same question:
#
#   1. Is RisingWave itself containerised?  It is an upstream product deployed by
#      its operator -- it has always run as containers. Nothing to do.
#   2. Is the PIPELINE (the DDL/ETL work) delivered the same way on both?  That is
#      the real question, and the record says no: dev executes SQL from an
#      in-cluster ARC GitHub runner, QA applies DDL from a built image as an Argo
#      CD sync-hook Job. Different mechanism, and different payload -- dev runs
#      pipelines/Brand, QA ran the smoke test.
#
# This reports what is actually there, so the answer comes from the clusters.
#
#   scripts/rw-pipeline-parity.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-onprem-ctx.sh"

report() {
  local BR="$1"
  echo
  echo "################################ $BR ################################"
  onprem_resolve_ctx "$BR" || { echo "  (unreachable)"; return; }
  local K=(kubectl --kubeconfig="$ONPREM_KC" --context="$ONPREM_CTX")

  echo
  echo "-- namespaces that matter"
  "${K[@]}" get ns -o name 2>/dev/null \
    | sed 's|namespace/||' \
    | grep -E '^(risingwave|risingwave-2|app-risingwave|arc-systems|arc-runners)$' \
    | sed 's/^/     /' || echo "     none"

  echo
  echo "-- RisingWave itself: is it running, and from which images"
  for NS in risingwave risingwave-2; do
    local pods
    pods=$("${K[@]}" -n "$NS" get pods --no-headers 2>/dev/null | wc -l)
    [ "$pods" -gt 0 ] || { echo "     $NS: absent"; continue; }
    echo "     $NS: $pods pods"
    "${K[@]}" -n "$NS" get pods \
      -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' 2>/dev/null \
      | sort -u | sed 's/^/       /'
  done

  echo
  echo "-- the ARC self-hosted runner (the DEV pipeline mechanism)"
  local arc
  arc=$("${K[@]}" get autoscalingrunnersets.actions.github.com -A --no-headers 2>/dev/null | wc -l)
  if [ "${arc:-0}" -gt 0 ]; then
    "${K[@]}" get autoscalingrunnersets.actions.github.com -A \
      -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,MIN:.spec.minRunners,MAX:.spec.maxRunners' --no-headers 2>/dev/null | sed 's/^/     /'
  else
    echo "     none -- this cluster does NOT run the ARC pipeline mechanism"
  fi

  echo
  echo "-- Argo CD Applications (the QA/prod delivery mechanism)"
  local apps
  apps=$("${K[@]}" -n argocd get applications.argoproj.io --no-headers 2>/dev/null | wc -l)
  if [ "${apps:-0}" -gt 0 ]; then
    "${K[@]}" -n argocd get applications.argoproj.io \
      -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,PATH:.spec.source.path,REV:.spec.source.targetRevision' --no-headers 2>/dev/null | sed 's/^/     /'
  else
    echo "     none"
  fi
  local as
  as=$("${K[@]}" -n argocd get applicationsets.argoproj.io --no-headers 2>/dev/null | wc -l)
  echo "     ApplicationSets: ${as:-0}"

  echo
  echo "-- app-risingwave: what the pipeline actually deployed"
  if "${K[@]}" get ns app-risingwave >/dev/null 2>&1; then
    "${K[@]}" -n app-risingwave get jobs,cronjobs,deploy --no-headers 2>/dev/null | sed 's/^/     /' || true
    echo "     images, and whether they are DIGEST-pinned (a tag can be moved; a digest cannot):"
    "${K[@]}" -n app-risingwave get pods \
      -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' 2>/dev/null \
      | sort -u | while read -r i; do
          [ -z "$i" ] && continue
          case "$i" in *@sha256:*) echo "       DIGEST $i" ;; *) echo "       TAG    $i   <-- not digest-pinned" ;; esac
        done
    echo "     PIPELINE_DIR, which decides whether anything REAL is applied:"
    "${K[@]}" -n app-risingwave get jobs -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.template.spec.containers[*].env[*]}{.name}={.value}{" "}{end}{"\n"}{end}' 2>/dev/null \
      | grep -o 'PIPELINE_DIR=[^ ]*' | sort -u | sed 's/^/       /' || echo "       (none found)"
  else
    echo "     namespace absent"
  fi
}

for BR in op-dev op-qa; do report "$BR"; done

cat <<'NOTE'

######################################################################
WHAT TO READ OFF THIS

Like-for-like requires BOTH to be true:
  * the same MECHANISM  -- an Argo CD Application applying a digest-pinned image,
    on both clusters. An ARC runner on one and Argo CD on the other is not parity,
    it is two systems.
  * the same PAYLOAD    -- PIPELINE_DIR pointing at the same real pipeline. A
    smoke test on one side and pipelines/Brand on the other is not parity either,
    and the smoke test is the one that proves nothing about the real DDL.

If QA shows an Argo CD Application with a digest-pinned image but PIPELINE_DIR is
smoke/, then the DELIVERY PATH is proven and the PIPELINE is not deployed. Those
are different claims and only the first one has been demonstrated.
NOTE

#!/usr/bin/env bash
# Why is a HelmRelease stuck, and what is the workload underneath it doing?
#
# The red/green signal is the workload's readiness, printed first. Everything
# after it is the evidence for one pass of diagnosis, captured in a single run
# so the answer does not need six round trips.
#
# READ ONLY. No pod is created (CLAUDE.md rule 3), nothing is applied, patched
# or deleted. Secret VALUES are never printed — only whether a key exists and
# how long it is.
#
#   scripts/capture-stuck-helmrelease.sh --context admin@op-usxpress-dev \
#       --namespace risingwave-2 --release prometheus
#   scripts/capture-stuck-helmrelease.sh --context admin@op-usxpress-dev \
#       --namespace wiz --release wiz-sensor
#
# Exit 0 = the workload is fully ready (the bug is gone).
#      1 = not ready — the signal is red, and the capture below says why.
#      2 = could not be determined.
set -uo pipefail

CTX=""; NS=""; REL=""; KCFG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --context)    CTX="$2"; shift 2 ;;
    --namespace)  NS="$2";  shift 2 ;;
    --release)    REL="$2"; shift 2 ;;
    --kubeconfig) KCFG="$2"; shift 2 ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$CTX" ] && [ -n "$NS" ] && [ -n "$REL" ] || {
  echo "usage: $0 --context <ctx> --namespace <ns> --release <helmrelease>" >&2; exit 2; }

k() { kubectl ${KCFG:+--kubeconfig="$KCFG"} --context "$CTX" "$@"; }
command -v jq >/dev/null || { echo "!! jq not installed" >&2; exit 2; }
hdr() { printf '\n=== %s ===\n' "$1"; }

echo "context:   $CTX"
echo "namespace: $NS"
echo "release:   $REL"

# ---------------------------------------------------------------- signal -----
# Every pod owned by this release, and whether each CONTAINER is ready. "1/2"
# in kubectl output does not say WHICH container is down; this does.
hdr "SIGNAL — container readiness"
PODS=$(k -n "$NS" get pods -l "app.kubernetes.io/instance=$REL" -o json 2>/dev/null)
COUNT=$(printf '%s' "${PODS:-{\}}" | jq -r '(.items // []) | length' 2>/dev/null || echo 0)
if [ "${COUNT:-0}" = "0" ]; then
  # Not every chart sets that label. Fall back to a name prefix.
  PODS=$(k -n "$NS" get pods -o json 2>/dev/null \
         | jq --arg r "$REL" '{items: [(.items // [])[] | select(.metadata.name | startswith($r))]}')
  COUNT=$(printf '%s' "$PODS" | jq -r '.items | length')
fi
if [ "${COUNT:-0}" = "0" ]; then
  echo "!! no pods found for release $REL in $NS — cannot determine readiness"
  NOTREADY=-1
else
  printf '%-46s %-36s %-6s %-9s %s\n' POD CONTAINER READY RESTARTS STATE
  printf '%s' "$PODS" | jq -r '.items[] as $p
    | ($p.status.containerStatuses // [])[]
    | [ $p.metadata.name, .name, (.ready|tostring), (.restartCount|tostring),
        ( if .state.running then "running since " + (.state.running.startedAt // "?")
          elif .state.waiting then "Waiting: " + (.state.waiting.reason // "?")
          elif .state.terminated then "Terminated: " + (.state.terminated.reason // "?")
               + " exit=" + ((.state.terminated.exitCode // 0)|tostring)
          else "?" end ) ] | @tsv' \
    | while IFS=$'\t' read -r P C R RC ST; do
        printf '%-46s %-36s %-6s %-9s %s\n' "$P" "$C" "$R" "$RC" "$ST"
      done
  NOTREADY=$(printf '%s' "$PODS" | jq -r '[.items[] | (.status.containerStatuses // [])[]
                                          | select(.ready == false)] | length')
  # The last exit of a crashing container is the whole story.
  printf '%s' "$PODS" | jq -r '.items[] as $p | ($p.status.containerStatuses // [])[]
    | select(.lastState.terminated != null)
    | "  last exit: \($p.metadata.name)/\(.name)  code=\(.lastState.terminated.exitCode) reason=\(.lastState.terminated.reason) at=\(.lastState.terminated.finishedAt)"'
fi

# ----------------------------------------------------------------- logs ------
hdr "LOGS — the container that is not ready (previous run, then current)"
if [ "${NOTREADY:-0}" -gt 0 ]; then
  printf '%s' "$PODS" | jq -r '.items[] as $p | ($p.status.containerStatuses // [])[]
      | select(.ready == false) | "\($p.metadata.name)\t\(.name)"' \
  | while IFS=$'\t' read -r P C; do
      echo "--- $P / $C  (previous) ---"
      k -n "$NS" logs "$P" -c "$C" --previous --tail=40 2>&1 | sed 's/^/    /'
      echo "--- $P / $C  (current) ---"
      k -n "$NS" logs "$P" -c "$C" --tail=40 2>&1 | sed 's/^/    /'
    done
else
  echo "(every container is ready — nothing to pull logs from)"
fi

# --------------------------------------------------------------- images ------
# Kyverno require-image-digest and require-approved-registry went Enforce on
# every on-prem cluster on 2026-08-21. allowExistingViolations=true means a pod
# already running is untouched, but a NEW ReplicaSet or DaemonSet pod is gated.
# A tag-not-digest image here means rolling forward will be REFUSED at admission.
hdr "IMAGES — do they satisfy the policies that went Enforce today?"
printf '%s' "${PODS:-{\"items\":[]\}}" | jq -r '[.items[] | (.spec.containers // [])[],
    (.spec.initContainers // [])[] | .image] | unique[]' 2>/dev/null \
  | while read -r IMG; do
      case "$IMG" in
        *@sha256:*) printf '  digest  %s\n' "$IMG" ;;
        *)          printf '  TAG     %s   <- would be REJECTED by require-image-digest\n' "$IMG" ;;
      esac
    done
echo "  namespace labels (the policies use a namespaceSelector):"
k get ns "$NS" -o jsonpath='{.metadata.labels}' 2>/dev/null | tr ',' '\n' | sed 's/^/    /'
echo

# -------------------------------------------------------------- rollout ------
hdr "ROLLOUT — was the new pod template ever admitted?"
k -n "$NS" get replicasets,daemonsets -o custom-columns=\
'KIND:.kind,NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas,AGE:.metadata.creationTimestamp' \
  2>/dev/null | grep -iE "NAME|$REL" || echo "  (none matching $REL)"

# --------------------------------------------------------------- events ------
hdr "EVENTS — last 25 in $NS, oldest first"
k -n "$NS" get events --sort-by=.lastTimestamp 2>/dev/null | tail -25 | sed 's/^/  /'

# --------------------------------------------------------------- storage -----
# prometheus-server crashing on a volume it cannot use is the classic cause, and
# on-prem that volume is rook-ceph.
hdr "STORAGE — PVCs in $NS"
k -n "$NS" get pvc 2>/dev/null | sed 's/^/  /' || echo "  (none)"

# --------------------------------------------------------------- secrets -----
# Presence and length ONLY. Never the value. A green ExternalSecret proves the
# sync ran, not that the content works (CLAUDE.md rule 4) — length is the
# cheapest tell for a placeholder that synced happily.
hdr "SECRETS — referenced by these pods (existence and length, never values)"
# imagePullSecrets are included deliberately: the first version of this script
# looked only at env/envFrom and printed nothing at all for wiz-sensor, whose
# entire failure was a 401 from the registry. The secret that matters is the one
# the kubelet uses, and it is never an env var.
printf '%s' "${PODS:-{\"items\":[]\}}" | jq -r '[.items[]
    | ((.spec.imagePullSecrets // [])[] | .name),
      ((.spec.containers // [])[], (.spec.initContainers // [])[]
       | ((.env // [])[] | select(.valueFrom.secretKeyRef) | .valueFrom.secretKeyRef.name),
         ((.envFrom // [])[] | select(.secretRef) | .secretRef.name))] | unique[]' 2>/dev/null \
  | while read -r S; do
      [ -n "$S" ] || continue
      J=$(k -n "$NS" get secret "$S" -o json 2>/dev/null)
      if [ -z "$J" ]; then echo "  $S — ABSENT"; continue; fi
      TYPE=$(printf '%s' "$J" | jq -r '.type // "Opaque"')
      printf '%s' "$J" | jq -r --arg s "$S" --arg t "$TYPE" '.data | to_entries[]
        | "  \($s) [\($t)] \(.key)  \((.value|@base64d|length)) chars"' 2>/dev/null \
        || echo "  $S — present, could not measure"
      # For a pull secret, WHICH registries it carries auth for is the diagnosis.
      # Hosts only — never the credential.
      if [ "$TYPE" = "kubernetes.io/dockerconfigjson" ]; then
        printf '%s' "$J" | jq -r '.data[".dockerconfigjson"] // empty | @base64d
          | (fromjson? // {}) | (.auths // {}) | keys[]
          | "      auth for: \(.)"' 2>/dev/null
      fi
    done
echo "  ExternalSecrets in $NS (SecretSynced proves the sync ran, not the value):"
k -n "$NS" get externalsecrets 2>/dev/null | sed 's/^/    /'

# -------------------------------------------------------------- verdict ------
hdr "VERDICT"
if [ "${NOTREADY:-0}" -lt 0 ]; then
  echo "UNDETERMINED — no pods found for $REL."; exit 2
elif [ "${NOTREADY:-0}" -gt 0 ]; then
  echo "RED — $NOTREADY container(s) not ready. The loop reproduces the bug."; exit 1
fi
echo "GREEN — every container of $REL is ready."

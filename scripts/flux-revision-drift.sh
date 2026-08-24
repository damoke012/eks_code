#!/usr/bin/env bash
# Is every Flux Kustomization actually AT the revision its source is serving?
#
# A merged PR plus a successful `flux reconcile source git` proves nothing about what is
# applied. On 2026-08-24 twelve Kustomizations on op-usxpress-qa sat one revision behind
# for 20+ minutes, and every one of them blamed a dependency that was Ready=True at that
# moment -- istio-csr blamed cert-manager-issuers, argocd-apps blamed app-namespaces,
# velero blamed external-secrets-config. grafana blamed prometheus on one poll and
# istio-ingress on the next while prometheus reported "health check passed in 72ms".
#
# The MESSAGE is the reason recorded at the last failed attempt, still displayed while
# the retry interval runs. It can name a component that is healthy right now, which
# sends you to debug the wrong thing. THE REVISION IS THE TRUTH.
#
# argocd-apps was among the twelve -- QA's app delivery path, frozen, reporting a healthy
# dependency as the blocker. Nothing else would have surfaced that.
#
#   scripts/flux-revision-drift.sh --cluster op-dev
#   scripts/flux-revision-drift.sh --cluster op-prod --print-fix
#
# Read-only. --print-fix PRINTS reconcile commands in dependency order; it never runs them.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-onprem-ctx.sh"

CLUSTER=""; NS="flux-system"; PRINT_FIX="no"
while [ $# -gt 0 ]; do
  case "$1" in
    --cluster) CLUSTER="$2"; shift 2 ;;
    --namespace) NS="$2"; shift 2 ;;
    --print-fix) PRINT_FIX="yes"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
onprem_resolve_ctx "$CLUSTER"
K() { kubectl --kubeconfig="$ONPREM_KC" --context="$ONPREM_CTX" "$@"; }

echo "== flux revision drift: $CLUSTER  ($ONPREM_ENDPOINT, node $ONPREM_NODE)"
echo

# Via FILES, not --argjson. A cluster's worth of Kustomization JSON on the command
# line exceeds ARG_MAX: "jq: Argument list too long", which reads like a jq bug.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
K -n "$NS" get kustomizations -o json > "$TMP/ks.json"
K get gitrepositories,ocirepositories,buckets -A -o json > "$TMP/src.json" 2>/dev/null \
  || echo '{"items":[]}' > "$TMP/src.json"

# Serve revision per source, keyed kind/namespace/name.
REPORT=$(jq -n --slurpfile ksf "$TMP/ks.json" --slurpfile srcf "$TMP/src.json" --arg ns "$NS" '
  ($ksf[0]) as $ks | ($srcf[0]) as $src
  | (($src.items // []) | map({ key: (.kind + "/" + .metadata.namespace + "/" + .metadata.name),
                                value: (.status.artifact.revision // "<no artifact>") })
     | from_entries) as $rev
  | $ks.items
  | map({
      name: .metadata.name,
      srcKey: ((.spec.sourceRef.kind // "GitRepository") + "/"
               + (.spec.sourceRef.namespace // $ns) + "/" + .spec.sourceRef.name),
      applied: (.status.lastAppliedRevision // "<never applied>"),
      ready: ((.status.conditions // []) | map(select(.type=="Ready")) | (.[0].status // "?")),
      msg:   ((.status.conditions // []) | map(select(.type=="Ready")) | (.[0].message // "")),
      deps:  ((.spec.dependsOn // []) | map(.name)),
      suspended: (.spec.suspend // false)
    })
  | map(. + { serving: ($rev[.srcKey] // "<unknown source>") })
  | map(. + { drift: (.applied != .serving) })
')

TOTAL=$(printf '%s' "$REPORT" | jq 'length')
DRIFTED=$(printf '%s' "$REPORT" | jq '[.[] | select(.drift and (.suspended|not))] | length')

printf '%s' "$REPORT" | jq -r '
  .[] | select(.drift and (.suspended|not))
  | "  \(.name)\n      applied : \(.applied)\n      serving : \(.serving)\n      ready   : \(.ready)   \(.msg)"'

echo
if [ "$DRIFTED" -eq 0 ]; then
  echo "OK: all $TOTAL Kustomizations are at the revision their source is serving."
  exit 0
fi

NEVER=$(printf '%s' "$REPORT" | jq '[.[] | select(.drift and (.suspended|not)
                                       and .applied == "<never applied>")] | length')
BEHIND=$((DRIFTED - NEVER))
[ "$BEHIND" -eq 0 ] || echo "!! $BEHIND of $TOTAL Kustomizations are BEHIND their source."
[ "$NEVER"  -eq 0 ] || echo "!! $NEVER of $TOTAL have NEVER applied -- blocked from the start,"
[ "$NEVER"  -eq 0 ] || echo "   not drifted. Their message is usually accurate."

# Which named dependencies are actually fine? That contrast is the whole point --
# and it is the ONLY case where the message should be distrusted. Warning about
# stale messages when the message is accurate just teaches people to ignore them.
STALE=$(printf '%s' "$REPORT" | jq -r '
  (map({key: .name, value: {ready: .ready, applied: .applied, serving: .serving}}) | from_entries) as $all
  | .[] | select(.drift and (.suspended|not))
  | . as $k
  | (.msg | capture("dependency .[^/]+/(?<dep>[^ ]+). is not ready") // null) as $c
  | select($c != null)
  | ($all[$c.dep] // null) as $d
  | select($d != null and $d.ready == "True" and $d.applied == $d.serving)
  | "   \($k.name) blames \($c.dep) -- but \($c.dep) is Ready=True and CURRENT (stale message)"')
if [ -n "$STALE" ]; then
  echo
  echo "   STALE MESSAGES -- these name a dependency that is healthy and current right now."
  echo "   The reason shown is the one recorded at the last failed attempt. Reconcile from"
  echo "   the ROOT of the chain; do not go debugging the component being blamed."
  printf '%s\n' "$STALE"
fi

if [ "$PRINT_FIX" = "yes" ]; then
  echo
  echo "-- reconcile in dependency order (drifted only). Reconcile from the ROOT of the"
  echo "   chain: each level only retries on its own timer, so a six-deep chain unwinds"
  echo "   slowly or not at all if you start in the middle."
  echo
  # Topological order over dependsOn, restricted to the drifted set. Kahn's
  # algorithm; anything left in a cycle is emitted last rather than dropped.
  printf '%s' "$REPORT" | python3 -c '
import json, sys
rows = [r for r in json.load(sys.stdin) if r["drift"] and not r["suspended"]]
names = {r["name"] for r in rows}
deps = {r["name"]: [d for d in r["deps"] if d in names] for r in rows}
out, seen = [], set()
while len(out) < len(rows):
    ready = sorted(n for n in names - seen if not set(deps[n]) - seen)
    if not ready:                      # cycle: emit the rest, do not drop them
        out.extend(sorted(names - seen)); break
    out.extend(ready); seen.update(ready)
for n in out:
    print("flux --kubeconfig=$ONPREM_KC --context=$ONPREM_CTX -n flux-system "
          "reconcile kustomization " + n)
'
  echo
  echo "   Substitute:  --kubeconfig=$ONPREM_KC --context=$ONPREM_CTX"
  if [ "$CLUSTER" = "op-prod" ]; then
    echo
    echo "   ⚠️  op-prod: these are PRINTED, not run. Reconciling prod is a deliberate act."
  fi
fi
exit 1

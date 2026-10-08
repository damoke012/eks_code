#!/usr/bin/env bash
# Finish the on-prem DNS work: measure BOTH halves of every hostname claim.
#
# READ-ONLY. Nothing here mutates a cluster, a zone or a repo.
#
# A hostname on these clusters needs three things, and DNS is only one:
#   1. an Istio VirtualService (or Gateway) declaring the host
#   2. an external-dns target annotation carrying THIS cluster's own node IPs
#   3. a Gateway that binds the port the host is served on
# external-dns then creates the record by itself. There is no networking request.
#
# THE TRAP THIS SCRIPT EXISTS TO AVOID
#   The usxpress.io SOA minimum is 86400, so a NEGATIVE answer is cached for 24 HOURS.
#   Resolving a name that has no record yet makes it unreachable for a day -- and
#   resolving it is exactly what you do to check whether it exists. So this asks
#   ROUTE 53 (an API call, no cache) and resolves ONLY what Route 53 confirms.
#
# Usage:  bash scripts/onprem-dns-finish.sh dev|qa|prod [...]
#         bash scripts/onprem-dns-finish.sh            # all three

set -uo pipefail

ZONE_ID=Z0658284PVIFD4Q8I9PO            # usxpress.io, network account 155768531003
ZONE_ROLE=arn:aws:iam::155768531003:role/iaac-route53-zone
HERE=$(cd -- "$(dirname -- "$0")" && pwd)

RRSET=$(mktemp); SAFE=$(mktemp)
trap 'rm -f "$RRSET" "$SAFE"' EXIT

# ---------------------------------------------------------------- Route 53 half
r53=NOT_MEASURED
if command -v aws >/dev/null 2>&1; then
  read -r ak sk st _ <<<"$(aws sts assume-role --role-arn "$ZONE_ROLE" \
      --role-session-name dns-finish --query Credentials --output text 2>/dev/null)"
  if [ -n "${ak:-}" ] && AWS_ACCESS_KEY_ID=$ak AWS_SECRET_ACCESS_KEY=$sk \
       AWS_SESSION_TOKEN=$st aws route53 list-resource-record-sets \
       --hosted-zone-id "$ZONE_ID" --output json > "$RRSET" 2>/dev/null; then
    r53=assumed-role
  elif aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
         --output json > "$RRSET" 2>/dev/null; then
    r53=current-identity
  fi
fi

printf '=== Route 53 zone %s (usxpress.io, account 155768531003)\n' "$ZONE_ID"
if [ "$r53" = NOT_MEASURED ]; then
  : > "$RRSET"
  printf '  NOT MEASURED -- could not read the zone, via %s or directly.\n' "$ZONE_ROLE"
  printf '  Every RECORD column below reads UNKNOWN. That is not absence.\n'
  printf '  Nothing will be resolved either: resolving an absent name costs 24h here.\n'
else
  printf '  read via %-16s %s record sets\n' "$r53" \
    "$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["ResourceRecordSets"]))' "$RRSET")"
  printf '  negative TTL (SOA minimum): '
  python3 -c 'import json,sys
for r in json.load(open(sys.argv[1]))["ResourceRecordSets"]:
    if r["Type"] == "SOA":
        v = r["ResourceRecords"][0]["Value"].split()[-1]
        print(v, "seconds", "<-- TOO LONG, 300-900 is typical" if int(v) > 900 else "")' "$RRSET"
fi

# ---------------------------------------------------------------- cluster half
for env in "${@:-dev qa prod}"; do
  kc="$HOME/.kube/op-usxpress-$env.yaml"
  [ "$env" = dev ] && [ -f "$HOME/.kube/op-usxpress-dev-fresh.yaml" ] \
    && kc="$HOME/.kube/op-usxpress-dev-fresh.yaml"
  ctx="admin@op-usxpress-$env"

  printf '\n=== op-usxpress-%s   (--context %s)\n' "$env" "$ctx"
  if [ ! -f "$kc" ]; then
    printf '  SKIPPED -- no kubeconfig at %s. This is NOT absence of a gap.\n' "$kc"
    continue
  fi
  export KUBECONFIG="$kc"

  if ! kubectl --context "$ctx" get --raw /readyz >/dev/null 2>&1; then
    printf '  ABORTED -- cannot reach the apiserver. A transport failure is not a finding.\n'
    continue
  fi

  nodes=$(kubectl --context "$ctx" get nodes \
    -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')
  printf '  nodes (%s): %s\n' "$(echo "$nodes" | grep -c .)" "$(echo "$nodes" | paste -sd, -)"

  printf '  Gateways in istio-ingress: '
  kubectl --context "$ctx" -n istio-ingress get gateways.networking.istio.io \
    -o go-template='{{range .items}}{{.metadata.name}}({{range .spec.servers}}{{.port.number}} {{end}}) {{end}}' \
    2>/dev/null || printf '(none)'
  echo
  printf '     ^ a VirtualService naming a Gateway that is absent here serves NOTHING,\n'
  printf '       with no error, no status condition and no event.\n'

  kubectl --context "$ctx" get virtualservices.networking.istio.io \
      gateways.networking.istio.io -A -o json 2>/dev/null \
  | ENV="$env" NODES="$nodes" python3 "$HERE/lib/onprem-dns-classify.py" \
      --rrset "$RRSET" --safe-list "$SAFE"
done

# ------------------------------------------------- resolve only what is confirmed
printf '\n=== resolve ONLY names Route 53 confirmed (nothing queried speculatively)\n'
if [ -s "$SAFE" ]; then
  sort -u "$SAFE" | while read -r h; do
    [ -z "$h" ] && continue
    if command -v dig >/dev/null 2>&1; then
      ips=$(dig +short +time=3 +tries=1 "$h" @8.8.8.8 2>/dev/null | paste -sd, -)
    else
      ips=$(getent hosts "$h" 2>/dev/null | awk '{print $1}' | paste -sd, -)
    fi
    if [ -z "$ips" ]; then
      printf '  %-44s NO ANSWER -- the record EXISTS in Route 53, so this is a resolver\n' "$h"
      printf '  %-44s problem (likely a cached negative), not a missing record.\n' ""
    else
      printf '  %-44s %s\n' "$h" "$ips"
    fi
  done
else
  printf '  nothing confirmed present, so nothing resolved. By design.\n'
fi

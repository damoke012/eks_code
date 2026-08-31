#!/usr/bin/env bash
# What DNS records will external-dns create for a cluster, and do they point at
# that cluster's own nodes?
#
# READ-ONLY. Records on these clusters are created by external-dns from annotations
# on Istio VirtualServices and Gateways (--source=istio-gateway,istio-virtualservice),
# not by hand and not by a networking request. This prints every claim a cluster makes
# and flags the two ways a copied manifest goes wrong:
#
#   * a hostname belonging to a DIFFERENT environment
#   * a target IP that is not one of THIS cluster's nodes
#
# Both are silent: external-dns skips records owned by another --txt-owner-id, so a
# copied VirtualService produces no error, no event, and no working hostname.
#
# Usage: bash onprem-dns-claims.sh dev|qa|prod [...]

set -uo pipefail

for env in "${@:-dev qa prod}"; do
  kc="$HOME/.kube/op-usxpress-$env.yaml"
  [ "$env" = dev ] && [ -f "$HOME/.kube/op-usxpress-dev-fresh.yaml" ] && kc="$HOME/.kube/op-usxpress-dev-fresh.yaml"
  ctx="admin@op-usxpress-$env"

  printf '\n=== op-usxpress-%s\n' "$env"
  if [ ! -f "$kc" ]; then
    printf '  SKIPPED — no kubeconfig at %s (this is not absence)\n' "$kc"
    continue
  fi

  export KUBECONFIG="$kc"

  owner=$(kubectl --context "$ctx" -n external-dns get deploy \
            -o jsonpath='{.items[*].spec.template.spec.containers[*].args}' 2>/dev/null \
          | tr ',' '\n' | grep -o 'txt-owner-id=[^"]*' | head -1)
  printf '  %s\n' "${owner:-txt-owner-id NOT FOUND — external-dns may not be running}"

  nodes=$(kubectl --context "$ctx" get nodes \
            -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2>/dev/null)

  kubectl --context "$ctx" get virtualservice,gateways.networking.istio.io -A -o json 2>/dev/null \
  | ENV="$env" NODES="$nodes" python3 -c '
import json, os, sys

env = os.environ["ENV"]
nodes = set(os.environ["NODES"].split())
data = json.load(sys.stdin)

for item in data.get("items", []):
    meta = item["metadata"]
    ann = meta.get("annotations") or {}
    target = ann.get("external-dns.alpha.kubernetes.io/target")
    hostname = ann.get("external-dns.alpha.kubernetes.io/hostname")

    hosts = item.get("spec", {}).get("hosts") or []
    if not hosts:
        for srv in item.get("spec", {}).get("servers", []):
            hosts.extend(srv.get("hosts") or [])
    if hostname:
        hosts.append(hostname)
    hosts = [h for h in hosts if h and h != "*"]
    if not hosts and not target:
        continue

    flags = []
    for h in hosts:
        if "usxpress.io" in h and f"op-{env}.usxpress.io" not in h:
            flags.append(f"HOST BELONGS TO ANOTHER ENV: {h}")
    if target:
        for ip in target.split(","):
            ip = ip.strip()
            if ip and ip not in nodes:
                flags.append(f"TARGET NOT A NODE OF THIS CLUSTER: {ip}")

    kind = item["kind"]
    ns = meta["namespace"]
    name = meta["name"]
    hostlist = ",".join(hosts) or "-"
    print("  %-15s %-16s %-26s %s" % (kind, ns, name, hostlist))
    if target:
        print(f"                  target: {target}")
    for f in flags:
        print(f"      MISMATCH  {f}")
'
done

printf '\nMISMATCH lines are copied manifests. They fail silently: external-dns skips\n'
printf 'records owned by another cluster, so nothing errors and nothing resolves.\n'

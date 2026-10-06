#!/usr/bin/env bash
# Read-only. Establishes which RisingWave UI each DNS name actually reaches on
# op-usxpress-dev, before anything is changed.
#
# ENVIRONMENT: op-usxpress-dev (on-prem Talos, 10.10.82.50). Aborts on any other cluster.
set -uo pipefail

export KUBECONFIG="$HOME/.kube/op-usxpress-dev-fresh.yaml"
NS=risingwave

echo "=== 0. prove the cluster ==="
INFO=$(kubectl cluster-info 2>&1 | head -1) || true
echo "$INFO"
case "$INFO" in
  *10.10.82.50*) echo "OK: op-usxpress-dev" ;;
  *) echo "ABORT: not op-usxpress-dev. Nothing below would mean anything."; exit 1 ;;
esac

echo
echo "=== 1. VirtualServices in $NS: host -> destination:port ==="
kubectl -n "$NS" get virtualservices.networking.istio.io \
  -o custom-columns='NAME:.metadata.name,HOSTS:.spec.hosts,GATEWAYS:.spec.gateways,DEST:.spec.http[*].route[*].destination.host,PORT:.spec.http[*].route[*].destination.port.number'

echo
echo "=== 2. the external-dns annotations that create the records ==="
for vs in $(kubectl -n "$NS" get virtualservices.networking.istio.io -o name); do
  echo "--- $vs"
  kubectl -n "$NS" get "$vs" -o jsonpath='{.metadata.annotations}{"\n"}'
done

echo
echo "=== 3. Services in $NS: port -> targetPort, and the selector ==="
kubectl -n "$NS" get svc \
  -o custom-columns='NAME:.metadata.name,TYPE:.spec.type,CLUSTERIP:.spec.clusterIP,PORTS:.spec.ports[*].port,TARGET:.spec.ports[*].targetPort,SELECTOR:.spec.selector'

echo
echo "=== 4. what actually listens: console pod vs meta pod ==="
for sel in 'app.kubernetes.io/name=risingwave-console' 'risingwave/component=meta'; do
  echo "--- $sel"
  kubectl -n "$NS" get pods -l "$sel" \
    -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[*].ready,PORTS:.spec.containers[*].ports[*].containerPort' 2>&1
done
echo "--- any pod whose name contains console (selector-independent)"
kubectl -n "$NS" get pods -o name | grep -i console || echo "(none)"

echo
echo "=== 5. what the names resolve to right now ==="
for h in risingwave-dashboard.op-dev.usxpress.io risingwave-console.op-dev.usxpress.io \
         rw-dashboard.op-dev.usxpress.io rw-console.op-dev.usxpress.io; do
  printf '%-45s ' "$h"
  getent hosts "$h" | awk '{printf "%s ", $1} END {if (NR==0) print "NXDOMAIN"; else print ""}'
done

echo
echo "=== 6. dev worker IPs — the target annotation for any NEW route ==="
kubectl get nodes \
  -o custom-columns='NAME:.metadata.name,IP:.status.addresses[?(@.type=="InternalIP")].address' \
  | grep -v control

echo
echo "=== 7. Gateways that could bind port 80/443 ==="
kubectl -n istio-ingress get gateways.networking.istio.io \
  -o custom-columns='NAME:.metadata.name,PORTS:.spec.servers[*].port.number,HOSTS:.spec.servers[*].hosts'

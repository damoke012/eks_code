#!/usr/bin/env bash
# Phase 1 step 4 — backfill prometheus_ingest=true on all pre-existing ServiceMonitor + PodMonitor.
# Run AFTER PR 2 (Kyverno mutation) lands. Run BEFORE PR 4 (selector flip).
# Run on WSL2 (codespace can't reach cluster).
#
# Idempotent. Skips resources that already have the label.

set -euo pipefail

echo "ServiceMonitors WITHOUT prometheus_ingest=true:"
kubectl get servicemonitor -A -o json \
  | jq -r '.items[] | select(.metadata.labels.prometheus_ingest != "true")
           | "\(.metadata.namespace) \(.metadata.name)"' \
  | tee /tmp/sm-to-label.txt

echo
echo "PodMonitors WITHOUT prometheus_ingest=true:"
kubectl get podmonitor -A -o json \
  | jq -r '.items[] | select(.metadata.labels.prometheus_ingest != "true")
           | "\(.metadata.namespace) \(.metadata.name)"' \
  | tee /tmp/pm-to-label.txt

echo
read -rp "Apply prometheus_ingest=true label to the above? [y/N] " yn
[[ "$yn" == "y" || "$yn" == "Y" ]] || { echo "Aborted."; exit 0; }

while read -r ns name; do
  [ -z "$ns" ] && continue
  echo "  labeling servicemonitor/$name in $ns"
  kubectl -n "$ns" label servicemonitor "$name" prometheus_ingest=true --overwrite
done < /tmp/sm-to-label.txt

while read -r ns name; do
  [ -z "$ns" ] && continue
  echo "  labeling podmonitor/$name in $ns"
  kubectl -n "$ns" label podmonitor "$name" prometheus_ingest=true --overwrite
done < /tmp/pm-to-label.txt

echo
echo "Verify (should be empty):"
kubectl get servicemonitor,podmonitor -A -o json \
  | jq -r '.items[] | select(.metadata.labels.prometheus_ingest != "true")
           | "\(.kind) \(.metadata.namespace)/\(.metadata.name)"'

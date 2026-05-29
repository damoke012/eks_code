#!/usr/bin/env bash
# verify-rw-baseline.sh — RW namespace health + Flux source-of-truth check.
#
# Used during PR review (Phase 3 — independent verification) on PRs that touch
# the `risingwave` ns. Captures the baseline so we can confirm RW is healthy
# before AND after a change.
#
# MUST run on WSL (codespace can't reach the cluster).
#
# Usage:
#   ./scripts/verify-rw-baseline.sh                       # defaults to ns=risingwave
#   ./scripts/verify-rw-baseline.sh risingwave-2          # check the other RW ns
#   NS=risingwave AWS_PROFILE=usx-dev ./scripts/verify-rw-baseline.sh
#
# Outputs all checks to stdout; exit non-zero only if kubectl itself fails.

set -uo pipefail

NS="${1:-${NS:-risingwave}}"
AWS_PROFILE="${AWS_PROFILE:-usx-dev}"

echo "== verify-rw-baseline.sh — ns=$NS aws_profile=$AWS_PROFILE =="
echo ""

echo "=== 1. RW CR status (Running expected) ==="
kubectl get rw -n "$NS" -o wide 2>&1
kubectl get rw -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{": "}{range .status.conditions[*]}{.type}={.status} {end}{"\n"}{end}' 2>&1

echo ""
echo "=== 2. RW stateStore (S3 bucket source-of-truth) ==="
kubectl get rw -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{":\n  bucket: "}{.spec.stateStore.s3.bucket}{"\n  region: "}{.spec.stateStore.s3.region}{"\n  dataDirectory: "}{.spec.stateStore.dataDirectory}{"\n  useServiceAccount: "}{.spec.stateStore.s3.credentials.useServiceAccount}{"\n"}{end}' 2>&1

echo ""
echo "=== 3. RW metaStore (postgres backend wiring) ==="
kubectl get rw -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{":\n  metaStore: "}{.spec.metaStore}{"\n"}{end}' 2>&1

echo ""
echo "=== 4. Pods + ages (recent activity narrative) ==="
kubectl get pods -n "$NS" -o wide 2>&1

echo ""
echo "=== 5. Pod labels (find real selector keys) ==="
kubectl get pods -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels}{"\n"}{end}' 2>&1 | head -20

echo ""
echo "=== 6. Compute resources (compare with any PR patch) ==="
kubectl get pods -n "$NS" -l risingwave/component=compute \
  -o jsonpath='{range .items[*]}{.metadata.name}{":\n"}{range .spec.containers[*]}  c={.name} req={.resources.requests} lim={.resources.limits}{"\n"}{end}{end}' 2>&1

echo ""
echo "=== 7. Postgres backend pod + Service wiring ==="
kubectl get pods -n "$NS" -l app.kubernetes.io/name=postgresql -o wide 2>&1
kubectl get svc -n "$NS" 2>&1 | grep -E "postgres|pg-" || true

echo ""
echo "=== 8. ExternalSecrets sync state (drift check) ==="
kubectl get externalsecret -n "$NS" 2>&1

echo ""
echo "=== 9. Recent events (sorted by lastTimestamp; last 4h activity story) ==="
kubectl get events -n "$NS" --sort-by=.lastTimestamp 2>&1 | tail -30

echo ""
echo "=== 10. Bucket existence + hummock data (skips if AWS SSO expired) ==="
BUCKET=$(kubectl get rw -n "$NS" -o jsonpath='{.items[0].spec.stateStore.s3.bucket}' 2>/dev/null)
if [[ -n "$BUCKET" ]]; then
  echo "Bucket from CR: s3://$BUCKET"
  aws s3 ls "s3://${BUCKET}/" --profile "$AWS_PROFILE" 2>&1 | head -5
  aws s3 ls "s3://${BUCKET}/hummock/" --profile "$AWS_PROFILE" 2>&1 | head -5
else
  echo "(no RW CR found in $NS; skipping bucket check)"
fi

echo ""
echo "=== done. ==="
echo ""
echo "Compare against PR patch values:"
echo "  - stateStore.bucket / region / dataDirectory"
echo "  - metaStore.host / postgres backend"
echo "  - compute resources.requests / .limits"
echo "  - operator HelmRelease version"
echo "  - any env/envFrom additions on meta/frontend/compute components"

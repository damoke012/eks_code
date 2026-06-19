#!/usr/bin/env bash
# Runs once when the Codespace is first created.
# Sets up a local k3d cluster, deploys the broken-pods scenario,
# and ensures the Go module compiles.

set -euo pipefail

exec > >(tee /tmp/post-create.log) 2>&1

echo "==> Installing k3d…"
curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | TAG=v5.7.4 bash

echo "==> Creating local k3d cluster 'sandbox'…"
k3d cluster create sandbox \
  --servers 1 \
  --agents 1 \
  --no-lb \
  --k3s-arg '--disable=traefik@server:*' \
  --wait || echo "(cluster may already exist — continuing)"

echo "==> Waiting for cluster to be ready…"
kubectl wait --for=condition=Ready node --all --timeout=120s || true
kubectl get nodes

echo "==> Deploying Exercise 02 broken pods…"
kubectl apply -f exercises/02-k8s-broken-pods/manifests/00-namespace.yaml
for i in {1..30}; do
  kubectl -n broken get sa default >/dev/null 2>&1 && break
  echo "  waiting for default ServiceAccount in broken ns ($i/30)…"
  sleep 1
done
kubectl apply -f exercises/02-k8s-broken-pods/manifests/

echo "==> Running 'go mod tidy' on Exercise 01…"
( cd exercises/01-go-mage-mini && go mod tidy && go build ./... ) || true

echo "==> Running 'terraform init' on Exercises 03 + 04…"
( cd exercises/03-aws-cross-account && terraform init -backend=false ) || true
( cd exercises/04-tf-state-split && terraform init -backend=false ) || true

echo ""
echo "================================================================"
echo "  Welcome to the USXpress Platform Engineering Interview Sandbox"
echo "================================================================"
echo ""
echo "  Open README.md to begin."
echo ""
echo "  Quick check commands:"
echo "    go version"
echo "    kubectl get nodes"
echo "    kubectl -n broken get pods"
echo "    terraform version"
echo ""
echo "================================================================"

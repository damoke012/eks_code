#!/usr/bin/env bash
# Runs once when the Codespace is created.
#   - installs k3d and creates a 2-node cluster
#   - deploys the Exercise 03 scenario (healthy rollout, then a stuck one)
#   - warms the Go module cache for Exercise 01
# Safe to re-run: everything is idempotent.
set -uo pipefail

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

log "Installing k3d"
if ! command -v k3d >/dev/null 2>&1; then
  curl -sfL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi

log "Creating cluster 'sandbox' (2 nodes)"
if ! k3d cluster list 2>/dev/null | grep -q '^sandbox'; then
  k3d cluster create sandbox --agents 1 --wait --timeout 180s
else
  k3d cluster start sandbox >/dev/null 2>&1 || true
fi

log "Waiting for nodes"
kubectl wait --for=condition=Ready nodes --all --timeout=180s || warn "nodes not ready yet"

# ---------------------------------------------------------------- exercise 03
log "Deploying Exercise 03 scenario"

kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: missions
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: missions-api-chart
  namespace: missions
data:
  APPLICATION__ENVIRONMENT: production
  APPLICATION__PROJECT: missions-api
  SERILOG__MINIMUMLEVEL__DEFAULT: Information
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: missions-api
  namespace: missions
  labels:
    app.kubernetes.io/name: missions-api
spec:
  replicas: 2
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app.kubernetes.io/name: missions-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: missions-api
    spec:
      containers:
        - name: missions-api
          image: nginx:1.27-alpine
          envFrom:
            - configMapRef:
                name: missions-api-chart
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet: { path: /, port: 80 }
            initialDelaySeconds: 2
            periodSeconds: 5
EOF

log "Waiting for the healthy rollout to settle"
kubectl -n missions rollout status deploy/missions-api --timeout=180s || warn "initial rollout slow"

# Now introduce the fault: a second envFrom pointing at a ConfigMap that does
# not exist. Running pods are unaffected; the new ReplicaSet cannot start.
log "Introducing the Exercise 03 fault"
kubectl -n missions patch deploy missions-api --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/envFrom/-",
   "value":{"configMapRef":{"name":"missions-api-m-u"}}}
]' >/dev/null

sleep 20

# ---------------------------------------------------------------- exercise 01
log "Warming the Go module cache for Exercise 01"
if [ -d exercises/01-go-spec-guard ]; then
  (cd exercises/01-go-spec-guard && go mod tidy >/dev/null 2>&1 && go build ./... >/dev/null 2>&1) \
    || warn "go mod tidy failed — the candidate can re-run it"
fi

# ---------------------------------------------------------------- summary
log "Environment summary"
echo
kubectl get nodes 2>/dev/null
echo
kubectl -n missions get pods 2>/dev/null
echo
printf '\033[1;32mReady.\033[0m Open README.md to begin.\n\n'
printf 'Expected state:\n'
printf '  - 2 nodes Ready\n'
printf '  - namespace "missions": 2 pods Running, 1 pod NOT starting\n'
printf '  - exercises/01-go-spec-guard builds and its tests pass\n\n'

# pod-identity-webhook directory — IaC notes

Current state (live cluster):
- `infrastructure/pod-identity-webhook/` has: certificate.yaml, deployment.yaml, mutatingwebhookconfiguration-patch.yaml, namespace.yaml, rbac.yaml, service.yaml, webhook.yaml
- NO kustomization.yaml at root (Flux uses default glob behavior)
- Live Deployment is 1 replica

## Two ways to apply the HA bump

### Option A: Edit deployment.yaml directly (simplest)

In `deployment.yaml`, change:
```yaml
spec:
  replicas: 1
```
to:
```yaml
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
```

Also add affinity at `spec.template.spec.affinity`:
```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          topologyKey: kubernetes.io/hostname
          labelSelector:
            matchLabels:
              app: pod-identity-webhook
```

### Option B: Apply via strategic merge patch (cleaner — needs kustomization.yaml)

Add a `kustomization.yaml` at the directory root:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - certificate.yaml
  - deployment.yaml
  - mutatingwebhookconfiguration-patch.yaml
  - rbac.yaml
  - service.yaml
  - webhook.yaml
patches:
  - target:
      kind: Deployment
      name: pod-identity-webhook
    path: deployment-patch.yaml
```

Then add `deployment-patch.yaml` (this draft) which only contains the replicas+affinity changes.

**Recommend Option A** — simpler, less moving parts, easier to review.

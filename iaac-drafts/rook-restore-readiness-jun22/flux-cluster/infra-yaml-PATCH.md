# Flux cluster repo — `clusters/bm-dev/flux-system/infra.yaml` patch

## Edit 1: Flip `external-secrets-config` from `wait: false` → `wait: true`

**Why:** With the structural fix in place (cross-cluster-eso split), the
`external-secrets-config` Kustomization now contains ONLY the `default` AWS-SM
ClusterSecretStore, which goes Ready in seconds. Standard `wait: true` is
restored.

**Find:**
```yaml
  name: external-secrets-config
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: infra
  path: ./infrastructure/external-secrets-config
  prune: true
  wait: false
  timeout: 5m
  dependsOn:
  - name: external-secrets
```

**Replace `wait: false` with `wait: true`** on the line scoped to this
Kustomization. Verify diff scope before commit (see memory
[[feedback_sed_range_anchor_indent]]).

## Edit 2: Add new `cross-cluster-app-secrets` Kustomization at end of file

**Why:** Holds ExternalSecrets that depend on the `cloud-eks` CSS (which itself
depends on the INFRA-1535 Octopus-seeded token). `wait: false` so the
Kustomization goes Ready as soon as resources are applied — ExternalSecrets
themselves will sit in `SecretSyncedError` until the runbook seeds the token,
then auto-sync without further git commits.

**Append at end of file (after the existing `cross-cluster-eso` block):**

```yaml

---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cross-cluster-app-secrets
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: infra
  path: ./infrastructure/cross-cluster-app-secrets
  prune: true
  wait: false
  timeout: 5m
  dependsOn:
  - name: cross-cluster-eso
  - name: app-namespaces
```

`dependsOn`:
- `cross-cluster-eso` ensures the cloud-eks CSS exists before the ES is applied
- `app-namespaces` ensures the `geoservices` namespace exists (though our edit
  also keeps the Namespace in app-secrets/, this dependency is correct in
  principle for any future cross-cluster app-namespace work)

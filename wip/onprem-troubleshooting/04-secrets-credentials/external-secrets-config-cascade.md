# external-secrets-config cascade — Octopus-runbook chicken-and-egg + Flux `wait: true` gating

**Status:** RESOLVED 2026-06-22. Cascade was blocking `app-secrets` + `octopus-worker` for 32 days at `observedGeneration: 1` (never reconciled since cluster bootstrap). Fixed by removing the orphan ExternalSecret that depended on the un-seedable CSS. Long-term fix proposed below.

**Symptom:**
- `flux get kustomizations -A` shows:
  ```
  external-secrets-config  Ready=False  health check failed after 5m0s: timeout waiting for: [ClusterSecretStore/cloud-eks status: 'InProgress']
  app-secrets              Ready=False  dependency 'flux-system/external-secrets-config' is not ready
  octopus-worker           Ready=False  dependency 'flux-system/external-secrets-config' is not ready
  ```
- ESO controller logs:
  ```
  cluster-secret-store cloud-eks: failed to prepare auth: failed to get cert from secret:
  cannot get Kubernetes secret "cloud-eks-reader-token" from namespace "external-secrets": secrets ... not found
  ```
- ClusterSecretStore `cloud-eks` is in terminal-failure state (`Ready=False`, `reason=InvalidProviderConfig`) since cluster creation date
- `kubectl -n flux-system get kustomization octopus-worker -o yaml` shows `observedGeneration: 1` (never moved past initial gen → never reconciled)

**Root cause:**

A chicken-and-egg dependency cycle baked into the cluster's bootstrap design:

```
external-secrets-config Kustomization  (wait: true)
  └─ ClusterSecretStore "cloud-eks"  (cross-cluster k8s provider)
      └─ k8s Secret "cloud-eks-reader-token"  (must contain bearer + CA from cloud EKS)
          └─ Seeded by "Seed Cross-Cluster ESO Token" Octopus runbook
              └─ Runs from OnPremise Octopus space's onprem-platform-bootstrap project
                  └─ Octopus worker deployment lives in `octopus-worker` Kustomization
                      └─ DEPENDS ON `external-secrets-config` being Ready
```

The Kustomization `wait: true` setting compounds the issue: it waits for ALL owned resources to be Ready (via kstatus). The CSS is owned by this Kustomization, so the Kustomization stays NotReady until the CSS goes Ready — which can't happen without the Octopus worker, which can't deploy until the Kustomization is Ready.

**Subtle Flux gotcha that "resolved" it accidentally:** Flux's kstatus library treats a Ready=False resource with a terminal `reason` (e.g., `InvalidProviderConfig`) as **"settled"** — not "in progress." If the CSS reports `Ready=False/InvalidProviderConfig` (terminal), Flux's `wait` is satisfied. If the CSS reports `Ready=False` initially without conditions populated (kstatus sees as "InProgress"), Flux waits forever.

In the 2026-06-22 recovery, the CSS condition transitioned from InProgress to terminal-Failed (perhaps after enough ESO controller restarts), which unblocked `external-secrets-config` Kustomization. But `app-secrets` then hit a similar block on the geoenrichment ExternalSecret (which was in `InProgress`, not terminal).

**IaC coverage:** ⚠ (the structural dependency is in IaC; the fix is structural)

**IaC location:**
- `iaac-talos-flux-platform/infrastructure/external-secrets-config/` — contains the CSS
- `iaac-talos-flux-platform/infrastructure/app-secrets/` — contains the ExternalSecrets that depend on CSSes
- `iaac-talos-flux-cluster/clusters/bm-dev/flux-system/infra.yaml` — defines Kustomizations + their wait settings

### Resolution applied 2026-06-22

**Tactical**: Removed the orphan `geoenrichment-sync-handler-m-u` ExternalSecret from `infrastructure/app-secrets/geoenrichment-sync-handler.yaml` (the SOLE consumer of cloud-eks CSS). Kept the Namespace + ConfigMap as pre-staging. The full ES manifest preserved as a comment in the file for verbatim restoration once the runbook seeds the secret.

PR: `iaac-talos-flux-platform#<TBD>` on `op-dev` branch.

After PR merge:
- `external-secrets-config` Ready=True (CSS now terminal-failed, no ExternalSecret references it)
- `app-secrets` Ready=True (orphan ES pruned by Flux)
- `octopus-worker` Ready=True (dependency unblocked)

### Resolution — recommended STRUCTURAL fix for QA cluster

For a fresh QA cluster, **separate the cross-cluster CSS into its own Kustomization** that can fail-independently without blocking the working `default` CSS or downstream consumers.

#### Step 1: Split the CSS manifests

Create new directory `iaac-talos-flux-platform/infrastructure/cross-cluster-eso/`:

```yaml
# kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - clustersecretstore.yaml
  - onprem-platform-rbac.yaml
```

```yaml
# clustersecretstore.yaml
# (Moved from external-secrets-config/clustersecretstore.yaml — ONLY the cloud-eks CSS)
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: cloud-eks
spec:
  provider:
    kubernetes:
      remoteNamespace: <ns>
      server:
        url: <eks api url>
        caProvider:
          type: Secret
          name: cloud-eks-reader-token
          namespace: external-secrets
          key: ca
      auth:
        token:
          bearerToken:
            name: cloud-eks-reader-token
            key: token
            namespace: external-secrets
```

```yaml
# onprem-platform-rbac.yaml
# (Moved as-is from external-secrets-config — the Octopus worker SA RBAC for seeding)
```

#### Step 2: Trim `external-secrets-config/clustersecretstore.yaml` to JUST the default CSS

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: default
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-2
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
```

#### Step 3: Add the new Kustomization to `iaac-talos-flux-cluster/clusters/<cluster>/flux-system/infra.yaml`

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cross-cluster-eso
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: infra
  path: ./infrastructure/cross-cluster-eso
  prune: true
  wait: false                     # KEY: do NOT block on CSS Ready
  timeout: 5m
  dependsOn:
  - name: external-secrets
```

**Why `wait: false`:** This Kustomization deploys only a CSS + RBAC — none of which require active health gating to be "deployed." The CSS will reconcile independently. Downstream consumers (ExternalSecrets) carry their own readiness through `app-secrets`.

#### Step 4: Document the bootstrap order in QA setup runbook

Add to `iaac-talos/deploy/docs/qa-cluster-bootstrap.md`:
- Step N: Apply `cross-cluster-eso` Kustomization (succeeds without secret)
- Step N+1: Run "Seed Cross-Cluster ESO Token" Octopus runbook (creates the `cloud-eks-reader-token` Secret)
- Step N+2: Verify CSS goes Ready (`kubectl get clustersecretstore cloud-eks`)
- Step N+3: Apply ExternalSecrets that depend on it (in `app-secrets/`)

This sequencing ensures:
- Octopus worker can deploy before cross-cluster CSS goes Ready
- Runbook can run via Octopus worker
- CSS becomes Ready when the runbook completes
- ExternalSecrets can sync afterwards

### Verification

```bash
flux get kustomizations -A | awk 'NR==1 || $4!="True"'
# Want: header row only (no NotReady Kustomizations)

# CSS reaches Ready after secret is seeded
kubectl get clustersecretstore cloud-eks -o jsonpath='{.status.conditions[0]}'
# Want: status=True, type=Ready

# Smoke test the bridge
# (apply an ExternalSecret that uses cloud-eks and confirm it syncs)
```

### Prevention

1. **One CSS per Kustomization** — don't bundle a maybe-broken CSS with a known-good one
2. **`wait: false` for config-only Kustomizations** — Kustomizations that own CSSes / ConfigMaps / Secrets with no health-gateable resources should use `wait: false` to avoid spurious gating
3. **Document Octopus-bootstrap-dependent resources clearly** — comment headers on every manifest that requires post-deployment runbook seeding so future operators understand the order
4. **PromRule `ClusterSecretStoreNotReady` (≥ 1 hour)** — alert when a CSS has been NotReady for over an hour, separate from kustomization status

### Related

- [[clustersecretstore-dns-dependency]] — different CSS-not-ready failure mode (AWS DNS during outage)
- [[externalsecret-stale-sync]] — downstream of CSS issues
- Memory: `[Flux prune inventory gotcha]`, `[Confirm before executing]`
- Memory pointer: `[Octopus worker progress]` (vendored chart in flux-platform; OnPremise space pending)

### Memory pointers

- 2026-06-22: ES `geoservices/geoenrichment-sync-handler-m-u` removed via PR (op-dev). cloud-eks CSS still un-seeded; planned to be seeded by `Seed Cross-Cluster ESO Token` runbook after OnPremise Octopus space is set up (INFRA-* follow-up).
- Original commit that introduced the design: iaac-talos-flux-platform `78af15d feat(onprem): cross-cluster ESO ClusterSecretStore + geo-handler ExternalSecrets` (2026-05-19)

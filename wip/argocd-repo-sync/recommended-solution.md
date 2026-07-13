# PR #73 — recommended solution for Idris

## The core point

RisingWave on op-usxpress-dev is **already GitOps via Flux** (operational since 2026-05-26):
- `variant-inc/iaac-risingwave-2` → Flux `GitRepository` + `Kustomization` (Ready=True), wired in `iaac-talos-flux-cluster master/clusters/bm-dev/flux-system/infra.yaml`.
- Platform standard is Flux end-to-end (Istio, ESO, ARC all Flux-managed).
- `iaac-talos-flux-platform/infrastructure/risingwave/` was **deleted as dead code in PR #7** — that repo is platform infra, NOT RW deployments.
- There is **no ADR/decision to adopt Argo CD.**

PR #73 adds a *second* GitOps controller to do what Flux already does → split-brain risk on a protected workload, in the path we just cleaned up. **Recommendation: don't merge; do the repo-sync in Flux.**

Likely intent: this looks like an attempt at **INFRA-1487 A2** — anchoring a RisingWave repo (probably `iaac-risingwave-onprem`, Tim's ns, currently NOT Flux-managed) to GitOps. The decided approach for that (Doke, 2026-05-28, "Option B") is **Flux GitRepository + Kustomization**, `prune: false`, Tim coord.

## The Flux-native equivalent (drop-in for what #73 tries to do)

### 1. SSH key via ExternalSecret (NOT a committed Secret) — mirrors the ARC PAT pattern
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: <rw-repo>-ssh
  namespace: flux-system
spec:
  refreshInterval: 1h
  secretStoreRef: { name: aws-secretsmanager, kind: ClusterSecretStore }
  target: { name: <rw-repo>-ssh, template: { type: Opaque } }
  data:
    - secretKey: identity
      remoteRef: { key: op-usxpress-dev/flux/<rw-repo>-deploy-key }
    - secretKey: known_hosts
      remoteRef: { key: op-usxpress-dev/flux/github-known-hosts }
```

### 2. GitRepository source (SSH)
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata: { name: <rw-repo>, namespace: flux-system }
spec:
  interval: 5m
  url: ssh://git@github.com/variant-inc/<rw-repo>.git
  ref: { branch: main }
  secretRef: { name: <rw-repo>-ssh }
```

### 3. Kustomization (the actual "sync")
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: { name: <rw-repo>, namespace: flux-system }
spec:
  interval: 10m
  sourceRef: { kind: GitRepository, name: <rw-repo> }
  path: ./manifests/op-usxpress-dev
  prune: false        # CRITICAL on first reconcile if anchoring out-of-band state
  wait: true
  targetNamespace: risingwave   # if Tim's ns → Tim coordination REQUIRED
```
Place these in `iaac-talos-flux-cluster master/.../flux-system/infra.yaml` (the established wiring point) — NOT in iaac-talos-flux-platform.

## Blocker → Flux-native fix

| #73 blocker | Fix |
|---|---|
| Argo CD as 2nd controller | Use the Flux GitRepository+Kustomization above. One controller, no split-brain. |
| `argocd_git_secret.yaml` plaintext | SSH key → SM → ExternalSecret (§1). Nothing secret in Git. |
| Namespace unconfirmed | `targetNamespace` explicit; if `risingwave`, Tim coord (INFRA-1487). |
| +67,612 lines / oversized-annotation → ServerSideApply | Non-issue in Flux: it doesn't write `last-applied-configuration`, so the oversized-annotation error never occurs. The workaround is unneeded. |
| Argo CD NodePort 31311/32119 | No Argo CD server = no NodePort. If a UI is ever wanted, front it with the Istio ingress + LE cert. |

## If Idris genuinely wants Argo CD (app-team self-service UI, etc.)
That's a legitimate "Flux-for-platform, Argo-for-apps" split — but it's an **architecture decision needing its own ADR + Doke buy-in**, with strict non-overlapping ownership (Argo owns only app resources in a dedicated ns Flux never touches). It does not ride in as a `chore:` PR on top of a workload Flux already owns.

## PR restructure suggestion
- **Close/convert #73.** Re-do the RW repo-sync as the Flux PR above.
- **Split out the Grafana "No Data" fix** (`9953ad1`) + RW streaming dashboards (`76c50b5`) + Prometheus refactor (`f0b0265`) into their own small PR — that part may be good and independently mergeable; don't lose it, just don't couple it to the Argo CD change.

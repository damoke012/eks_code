# Tracks 4 + 5 + INFRA-1537 — PR plan (2026-06-22 EOD)

**Scope:** Close all IaC-able restore-readiness items left on the slate.

## PR-G (iaac-talos-flux-platform op-dev) — Multi-track IaC bundle

### Track 4 — Observability hygiene

- `infrastructure/prometheus/dns-health.yaml` — PromRule with 5 alerts (CoreDNSPodDown, CoreDNSPanic, CoreDNSHighErrorRate, ClusterDNSUnreachable, KubeDNSServiceEndpointMissing)
- `infrastructure/prometheus/irsa-health.yaml` — PromRule with 5 alerts (ExternalSecretSyncError, ClusterSecretStoreNotReady, PodIdentityWebhookDown, PodIdentityWebhookCAInvalid, IRSATokenInjectionFailure)
- `infrastructure/prometheus/kustomization.yaml` — add both files to resources list

### Track 5 — Secret-change resilience

- NEW `infrastructure/reloader/` directory with stakater/reloader HelmRelease:
  - `namespace.yaml`
  - `helmrepository.yaml`
  - `helmrelease.yaml` — watchGlobally, autoReloadAll=false (opt-in only via reloader.stakater.com/auto annotation), ignoredNamespaces for kube-system/flux-system/rook-ceph/istio-*/cilium-secrets
  - `kustomization.yaml`
- ES refreshInterval 1h → 5m on ~16 critical-path ExternalSecrets (sed across `infrastructure/app-secrets/` + `infrastructure/cross-cluster-app-secrets/`)

### INFRA-1537 — pod-identity-webhook caBundle auto-refresh

- NEW `infrastructure/pod-identity-webhook/certificate.yaml` — selfsigned Issuer + CA Cert + CA Issuer + webhook serving Cert
- NEW `infrastructure/pod-identity-webhook/mutatingwebhookconfiguration-patch.yaml` — strategic merge patch adding `cert-manager.io/inject-ca-from` annotation
- EDIT `infrastructure/pod-identity-webhook/kustomization.yaml` — append `certificate.yaml` to resources + add `patches` block

### Verification after merge

```bash
kubectl get prometheusrule -n prometheus dns-health irsa-health
kubectl -n reloader get deploy
kubectl get mutatingwebhookconfiguration pod-identity-webhook -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | wc -c   # non-zero
kubectl -n pod-identity-webhook get certificate
grep -c "refreshInterval: 5m" infrastructure/app-secrets/*.yaml infrastructure/cross-cluster-app-secrets/*.yaml
```

## PR-H (iaac-talos-flux-cluster master) — Add reloader Kustomization

- EDIT `clusters/bm-dev/flux-system/infra.yaml` — append `reloader` Kustomization at end of file (wait: true, dependsOn cert-manager)

## INFRA-1535 (separate, iaac-octopus-onprem repo) — Octopus space IaC

Drafted under `octopus-onprem-scaffold/`:
- Terraform module for OnPremise space
- onprem-platform-bootstrap project definition
- Seed-Cross-Cluster-ESO-Token runbook (PowerShell step body)
- Step: read cloud EKS service-account token from a designated secret in AWS SM → kubectl-apply to op-usxpress-dev as `external-secrets/cloud-eks-reader-token` Secret

**Status: scaffold only.** Standing it up live requires Octopus admin token + verification against the cloud EKS source SA. Defer to next session.

## INFRA-1536 (operational, not IaC) — Mon PVC expand

IaC value already 20Gi (PR #48). Existing PVCs are 10Gi on local-path which **does NOT support online expansion**. Plan: mon-by-mon recreate.

See `docs/mon-recreate-runbook.md` in this draft directory for the careful sequence (one mon at a time; verify quorum between each; protect Tim's RW).

## Operational housekeeping

- Octopus iaac-talos project — verify TfApply variable is `false`. If not, flip.
- Ping Idris re: argocd/argocd-admin-credentials ES SecretSyncedError (his track).

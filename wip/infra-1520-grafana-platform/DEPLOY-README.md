# INFRA-1520 — Grafana Platform Deploy (PR-1+2+3+4 bundled)

Tonight's shippable bundle. Mimir + Loki + Promtail + Alertmanager wait for Rook-Ceph maintenance window.

## What ships

| Component | Where |
|---|---|
| Grafana namespace + ExternalSecret + HelmRepo + HelmRelease + values + VS | `iaac-talos-flux-platform op-dev` → `infrastructure/grafana/` |
| Kyverno ClusterPolicy: auto-add `grafana_folder=<namespace>` annotation | `iaac-talos-flux-platform op-dev` → `infrastructure/kyverno-policies/auto-grafana-folder-label.yaml` |
| Flux Kustomization CR for grafana | `iaac-talos-flux-cluster master` → `clusters/bm-dev/flux-system/infra.yaml` (appended) |

## Why this configuration

- **Persistence**: local-path PVC 10Gi RWO, StatefulSet pinned to first-attach worker. Dashboards live in ConfigMaps (Bento → git) so only UI prefs + alert state are lost on worker disk failure. Acceptable for dev; Rook-Ceph migration when storage backbone lands.
- **No per-host TLS cert**: `grafana.op-dev.usxpress.io` is covered by the existing `*.op-dev.usxpress.io` wildcard cert (`wildcard-op-dev-tls`) on the shared-http Gateway's `https-op-dev` server block. No Gateway patch needed.
- **No AAD SSO yet**: admin user/password via ExternalSecret from AWS SM at `op-usxpress-dev/platform/grafana`. Azure AD SSO is a follow-up PR once IT delivers the app reg + reply URL.
- **Sidecar with `folderAnnotation: grafana_folder`**: reads ConfigMaps cluster-wide with `grafana_dashboard=1` label; lands them in the folder named by the `grafana_folder` annotation.
- **Kyverno mutation**: auto-sets `grafana_folder=<namespace>` annotation on any CM matching the dashboard label. Apps don't have to set the folder explicitly — they just ship a dashboard CM in their namespace.
- **DR-portable**: same Bento-pattern CM from cloud will land in the right folder on-prem with zero modification.

## Pre-merge checklist

```bash
# 1. Create the SSM secret if it doesn't exist (one-time)
aws secretsmanager create-secret \
  --name op-usxpress-dev/platform/grafana \
  --secret-string '{"username":"admin","password":"<generate-with-openssl-rand-base64-24>"}' \
  --profile usx-dev \
  --region us-east-2

# 2. Verify wildcard cert is healthy (it should be — Phase 0 work)
kubectl -n istio-ingress get cert wildcard-op-dev | grep True

# 3. Confirm Prometheus Service name matches the values file
kubectl -n prometheus get svc | grep prometheus-stack-kube-prom-prometheus
#   If named differently, update grafana-values ConfigMap before applying.

# 4. Confirm Kyverno controller is healthy (admission mutation depends on it)
kubectl get cpol 2>/dev/null | head
flux get kustomization kyverno -n flux-system
```

## Apply order

1. **Platform PR** (iaac-talos-flux-platform op-dev):
   ```
   infrastructure/grafana/                              ← whole module
   infrastructure/kyverno-policies/auto-grafana-folder-label.yaml  ← one file added to existing module
   ```
2. **Cluster PR** (iaac-talos-flux-cluster master):
   ```
   clusters/bm-dev/flux-system/infra.yaml               ← append the new Kustomization CR
   ```
3. **SSM secret** (above bash block)
4. Merge platform PR → Flux fetches infra GitRepository
5. Merge cluster PR → Flux applies the new Kustomization CR
6. Force reconcile:
   ```bash
   flux reconcile source git infra -n flux-system
   flux reconcile kustomization flux-system
   flux reconcile kustomization kyverno-policies -n flux-system
   flux reconcile kustomization grafana -n flux-system
   ```

## Post-deploy validation

```bash
# 1. Grafana pod healthy
kubectl -n grafana get pods,pvc,svc

# 2. Kyverno applied folder annotation to Tim's RW dashboard
kubectl -n risingwave get cm grafana-dashboard-risingwave-core -o jsonpath='{.metadata.annotations.grafana_folder}'
# Expected: risingwave

# 3. DNS resolves
dig +short grafana.op-dev.usxpress.io
# Expected: 7 worker IPs

# 4. HTTPS reaches Grafana login
curl -sI https://grafana.op-dev.usxpress.io | head -5
# Expected: HTTP/2 302, location: /login (per cloud Grafana pattern)

# 5. Log in with admin creds from SSM
aws secretsmanager get-secret-value \
  --secret-id op-usxpress-dev/platform/grafana \
  --profile usx-dev --region us-east-2 \
  | jq -r '.SecretString' | jq

# 6. After login: verify RW dashboard appears in "risingwave" folder
#    Browse to: https://grafana.op-dev.usxpress.io/dashboards
#    Expected: see "risingwave" folder with "RisingWave Core" dashboard inside.
```

## RW protection

This deploy touches ONLY:
- new `grafana` namespace
- new files in `infrastructure/grafana/` and `infrastructure/kyverno-policies/`
- new line in `infra.yaml`

Touches NOTHING in `risingwave` namespace. RW services, pods, secrets, PVCs all untouched. The Kyverno mutation is in-place — only adds an annotation to the existing CM, doesn't modify Flux's source.

If anything breaks:
```bash
flux suspend kustomization grafana -n flux-system   # stops reconciliation
kubectl delete clusterpolicy auto-grafana-folder-label  # removes the mutation
```
Both reversible; RW unaffected.

## Follow-up PRs (not in this bundle)

- AAD SSO when IT delivers the app reg
- Mimir HelmRelease + Prom remote_write (post-Rook-Ceph)
- Loki HelmRelease + Promtail DaemonSet (post-Rook-Ceph)
- Alertmanager + PD ExternalSecret + routing (separate from Grafana, post-Rook-Ceph)
- Coordinate with Idris on `op-usxpress-dev/risingwave/grafana` SSM secret — clarify if it was meant for THIS Grafana or RW-specific; consolidate if needed.

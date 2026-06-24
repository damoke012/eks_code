# Grafana on-prem Phase 4 — IaC closeout (INFRA-1520)

## Summary

Brings on-prem Grafana to Phase 4 acceptance per [INFRA-1520](https://usxpress.atlassian.net/browse/INFRA-1520):

- **Storage migration**: `local-path` (single-node pinned) → `ceph-block` (Rook-Ceph backed, replicated). INFRA-1532 (Rook-Ceph) is Done so the dependency note in the prior values block is now unblocked.
- **Baseline dashboard**: ships a hand-rolled "Kubernetes Cluster Overview (op-usxpress-dev)" dashboard via ConfigMap. Picked up by the existing dashboard sidecar; placed under the `grafana` folder by the existing `auto-grafana-folder-label` Kyverno policy.
- **Azure AD SSO config skeleton**: `[auth.azuread]` block + Microsoft Entra tenant URLs + envFromSecret wired. `enabled: false` for now — see "Why SSO is shipped disabled" below.
- **ExternalSecret for Azure AD client credentials**: pulls from new SM secret `op-usxpress-dev/platform/grafana/azure-ad`, renders as `GF_AUTH_AZUREAD_CLIENT_ID` / `GF_AUTH_AZUREAD_CLIENT_SECRET` env vars (Grafana auto-maps).
- **Prometheus datasource**: confirmed already configured in chart values (line 101-114 of helm-values-configmap.yaml — no change needed).

## Files

| File | Change | Purpose |
|---|---|---|
| `infrastructure/grafana/helm-values-configmap.yaml` | MODIFY | flip `persistence.storageClassName` to ceph-block, add `[auth.azuread]` skeleton (enabled: false), add `envFromSecret: grafana-azure-ad-creds` |
| `infrastructure/grafana/externalsecret-azure-ad.yaml` | NEW | ExternalSecret pulling Azure AD client creds → env-var-format Secret |
| `infrastructure/grafana/dashboard-kubernetes-cluster.yaml` | NEW | Baseline K8s cluster dashboard (4 stat panels + 3 timeseries; cluster CPU/mem, pod count, per-node usage, per-namespace pod count) |
| `infrastructure/grafana/kustomization.yaml` | MODIFY | add the 2 new files to resources |

## Why SSO is shipped disabled

Registering the Azure AD OAuth app requires Application Administrator (or higher) role on the USXPress Entra tenant — Doke doesn't have that role today (verified via portal.azure.com → "You don't have access" 401 on the Active Directory blade).

Tracked as [INFRA-1558](https://usxpress.atlassian.net/browse/INFRA-1558) for the IT lead to register the app. Once registered:

```bash
# Replace placeholders with real values from the registered app
aws secretsmanager put-secret-value \
  --secret-id op-usxpress-dev/platform/grafana/azure-ad \
  --secret-string '{"client_id":"<APP-ID>","client_secret":"<SECRET-VALUE>"}' \
  --profile usx-dev --region us-east-2

# Then a 1-line PR: flip enabled: false -> true in helm-values-configmap.yaml
```

Until then, admin login via username/password (existing `grafana-admin` ExternalSecret) is the only login path.

## PVC migration procedure (run AFTER merge)

The chart cannot change `storageClassName` on an existing PVC in place. Procedure (run from WSL where you have cluster reach):

```bash
export KUBECONFIG=~/.kube/op-usxpress-dev.yaml

# 1. Pre-backup the grafana namespace via Velero (safety net)
velero backup create grafana-pre-cephblock-migration \
  --include-namespaces grafana --wait
velero backup describe grafana-pre-cephblock-migration | grep Phase
# Expect: Phase: Completed

# 2. Suspend Flux reconcile on the grafana Kustomization so the chart
#    doesn't fight the manual cleanup
flux suspend kustomization grafana -n flux-system

# 3. Suspend the HelmRelease itself, scale to 0, delete the PVC
flux suspend helmrelease grafana -n grafana
kubectl -n grafana scale deployment grafana --replicas=0
kubectl -n grafana delete pvc grafana

# 4. Confirm PVC + PV gone, then un-suspend
kubectl -n grafana get pvc                   # empty
flux resume helmrelease grafana -n grafana
flux resume kustomization grafana -n flux-system

# 5. Watch the new PVC bind on ceph-block (~30s)
kubectl -n grafana get pvc -w
# Expected:
#   NAME      STATUS   STORAGECLASS   ...
#   grafana   Bound    ceph-block     ...

# 6. Confirm Grafana pod re-creates and Reaches Ready
kubectl -n grafana get pod -l app=grafana -w

# 7. Sanity-check the baseline dashboard renders
# Browser: https://grafana.op-dev.usxpress.io
# Login with admin/<password from SM>
# Navigate: Dashboards -> grafana folder -> "Kubernetes Cluster Overview (op-usxpress-dev)"
# Confirm at least: Nodes count, Pods total, Cluster CPU %, Cluster Memory % render values.
```

If anything goes wrong: `velero restore create grafana-cephblock-rollback --from-backup grafana-pre-cephblock-migration --include-namespaces grafana --wait`.

## Acceptance verification (after merge + migration)

INFRA-1520 acceptance criteria (scope-reduced — see ticket comment for the deferral):

- [ ] `https://grafana.op-dev.usxpress.io` resolves and Grafana login page renders (no SSO yet — username/password)
- [ ] Datasource "Prometheus" is **Healthy** (Configuration → Data sources → Prometheus → Test)
- [ ] Dashboard "Kubernetes Cluster Overview (op-usxpress-dev)" renders with non-empty stat panels
- [ ] `kubectl -n grafana get pvc grafana` shows `STORAGECLASS=ceph-block STATUS=Bound`
- ~~Test alert from Grafana → PD page + FS ticket~~ — **deferred to Phase 2 (INFRA-1517)**

## Tickets

- INFRA-1520 (Observability Phase 4: Grafana on-prem) — closes after merge + verification above
- INFRA-1558 (NEW: Azure AD OAuth app registration for Grafana SSO) — sub-ticket, IT lead assignee
- INFRA-1517 (Observability Phase 2: Alertmanager + PagerDuty + Freshservice) — referenced as future home for PD/FS routing
- INFRA-1544 (marathon umbrella) — Phase 4 closeout extends the marathon scope

## Notes for reviewers

- Resource limits (cpu 1000m / memory 1Gi) preserved; persistence size 10Gi preserved.
- Sidecar `searchNamespace: ALL` preserved — keeps the Bento pattern (apps ship dashboards as labeled CMs from any namespace).
- Cluster-wide RBAC (`rbac.namespaced: false`) preserved — required for sidecar's cross-namespace search.
- The hand-rolled dashboard uses only `kube_*` and `node_*` metrics which are guaranteed by kube-state-metrics + node-exporter (already deployed in `prometheus` ns). No additional exporter needed.
- The dashboard ConfigMap lives in `grafana` namespace; Kyverno `auto-grafana-folder-label` will annotate `grafana_folder=grafana`. Folder name in Grafana will be `grafana`. Rename later if desired.

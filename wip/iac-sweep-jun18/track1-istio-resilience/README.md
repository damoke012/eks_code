# Track 1 — Istio resilience

**Why this exists:** the 2026-06-18 grafana 503 incident silently degraded for 21h because we had no alert on `pilot_xds_connected_endpoints == 0` and no defensive restart cadence on the gateway DS. This track adds detection + a hedge.

## Files

| File | Purpose | Target repo / path |
|---|---|---|
| `prometheusrule-istio-cert-chain.yaml` | Alerts on `ConnectedEndpoints=0`, istio-csr not Ready, gateway cert TTL < 24h | `iaac-talos-flux-platform/infrastructure/prometheus-rules/` |
| `istiod-service-pinned-clusterip-patch.yaml` | Kustomize patch to pin istiod's Service ClusterIP | `iaac-talos-flux-platform/infrastructure/istio/istiod/` (added to existing `patches:`) |
| `cronjob-weekly-gateway-restart.yaml` | Defensive weekly rolling restart of istio-ingressgateway DS | `iaac-talos-flux-platform/infrastructure/istio/cronjobs/` (new folder; reference from istio Kustomization) |

## PR sequence

1. PR `prometheusrule-istio-cert-chain.yaml` first — pure detection, zero blast radius
2. PR `istiod-service-pinned-clusterip-patch.yaml` — verify the current ClusterIP matches the value in the patch (`10.101.33.234`) on op-usxpress-dev before merging; QA cluster picks its own
3. PR `cronjob-weekly-gateway-restart.yaml` last — wait for first scheduled run to confirm IAM/RBAC works before relying on it

## Validation after merge

```bash
# PromRule loaded?
kubectl -n monitoring get prometheusrule istio-cert-chain
# Force-evaluate the rules by checking Prometheus targets
# (Prometheus reload is automatic via prometheus-operator)

# Pinned ClusterIP
kubectl -n istio-system get svc istiod -o jsonpath='{.spec.clusterIP}'
# Should equal the value in the patch

# CronJob scheduled
kubectl -n istio-ingress get cronjob istio-ingressgateway-weekly-restart
```

## Risks / caveats

- The pinned ClusterIP is environment-specific. **Do not blindly carry the IP from op-usxpress-dev into QA — pick a desired IP from the QA Service CIDR.**
- The cert TTL metric (`istio_agent_cert_expiry_seconds`) may not be surfaced today. If it's missing, the alert won't fire — verify with `kubectl -n istio-ingress exec ... -- pilot-agent request GET stats | grep cert_expiry`. If not present, fall back to `citadel_server_csr_signing_failures_total` rate, or open a separate ticket to enable the metric (small Helm values bump).
- CronJob runs `kubectl rollout restart` from in-cluster — the ServiceAccount only gets DS patch on `istio-ingress` namespace. No cluster-wide perms.

## Related lessons codified

- [[incident_2026_06_18_cilium_orphan_cert_cascade]]
- `/onprem-safety` Rule 8 — cert/mTLS health is a 24h ticking bomb

# Track 1.5 — Cilium hygiene (stale CiliumNode detection)

**Why this exists:** the 2026-06-18 grafana 503 incident was caused by an orphan CiliumNode left behind by yesterday's hostname patch on `.29`. No alert fired for 21h because there was no monitoring of CiliumNode vs k8s Node count.

## Files

| File | Purpose | Target repo / path |
|---|---|---|
| `prometheusrule-cilium-node-divergence.yaml` | Alerts on `count(CiliumNodes) != count(Nodes)` | `iaac-talos-flux-platform/infrastructure/prometheus-rules/` |
| `cronjob-ciliumnode-reconciler.yaml` | Hourly detection + (optional) auto-remediation Job | `iaac-talos-flux-platform/infrastructure/cilium/hygiene/` (new folder) |

## PR sequence

1. PR `prometheusrule-cilium-node-divergence.yaml` first — detection only
2. PR `cronjob-ciliumnode-reconciler.yaml` second, with `DRY_RUN=true` (default)
3. Wait one week, observe dry-run output — should show "OK" hourly unless a node is renamed
4. **Optional later:** flip `DRY_RUN=false` if comfortable with auto-remediation

## Validation after merge

```bash
# PromRule loaded?
kubectl -n monitoring get prometheusrule cilium-node-divergence

# CronJob scheduled?
kubectl -n kube-system get cronjob ciliumnode-reconciler

# Force-run the Job once to confirm it works
kubectl -n kube-system create job --from=cronjob/ciliumnode-reconciler ciliumnode-reconciler-manual
kubectl -n kube-system logs job/ciliumnode-reconciler-manual
# Expect: "OK — no orphan CiliumNodes."
```

## Risks / caveats

- The PromRule depends on kube-state-metrics being configured to expose CRD counts (`kube_customresource_*`). If today's kube-state-metrics doesn't surface `cilium.io/v2/CiliumNode`, the alert silently won't fire. Validation: `kubectl get --raw /metrics | grep ciliumnode_info`. If empty, **add CRD config to kube-state-metrics Helm values** OR rely on the CronJob's Job-failure signal instead.
- The CronJob defaults to `DRY_RUN=true` — it will FAIL when it detects divergence, surfacing via the standard CronJob failure alerts. This is intentional — flag, don't auto-act, until trusted.
- ClusterRole needs `delete` on `ciliumnodes` to actually remediate; if your security review wants to reject that, run the Job in dry-run forever and use the alert as the only signal.

## Related lessons codified

- [[incident_2026_06_18_cilium_orphan_cert_cascade]]
- `/onprem-safety` Rule 7 — hostname patch ↔ Cilium reconciliation cleanup

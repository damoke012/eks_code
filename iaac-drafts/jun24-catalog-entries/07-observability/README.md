# 07 — Observability

Catalog entries for the kube-prometheus-stack + Grafana stack on op-usxpress-dev, captured during the 2026-06-23/24 Phase 4 closeout (INFRA-1520).

| Entry | Symptom | Resolution |
|---|---|---|
| [kube-prometheus-stack-memory-oom](kube-prometheus-stack-memory-oom.md) | Prometheus OOMKills during WAL replay | Bump memory limit to 4Gi |
| [grafana-datasource-uid-mismatch](grafana-datasource-uid-mismatch.md) | Dashboards show "No Data" despite healthy datasource | Pin `uid: prometheus` + `deleteDatasources` block |
| [node-exporter-hostport-9100-collision](node-exporter-hostport-9100-collision.md) | node-exporter pods Pending in mixed-chart envs | Set `hostNetwork: false` on the newer chart |
| [velero-restore-test-ns-sm-leak](velero-restore-test-ns-sm-leak.md) | Inflated metric cardinality after Velero restore exercise | Always `kubectl delete ns restore-test` post-restore |
| [helm-pvc-adoption-after-delete](helm-pvc-adoption-after-delete.md) | Deployment stuck at replicas=0 after PVC delete | Manually apply PVC with Helm adoption labels |

Source PRs (`variant-inc/iaac-talos-flux-platform`): #63, #65, #66, #67, #68, #69 + 2 manual ops (Grafana PVC adoption + kube-prometheus-stack uninstall/reinstall).

ADR-001 context: [Observability Phase 0](https://github.com/variant-inc/iaac-talos-flux-platform/blob/op-dev/op-dev/docs/decisions/ADR-001-observability-phase0.md).

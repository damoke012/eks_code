# kube-prometheus-stack Prometheus OOMKilled during WAL replay

**Symptom:**
- Prometheus pod in `prometheus` namespace shows `2/2 Running` briefly, then `CrashLoopBackOff`
- `kubectl describe pod` reveals exit code 137 (OOMKilled) on the `prometheus` container
- Restarts climb steadily (5, 8, 12...) without stabilising
- Grafana panels show "No Data" intermittently — datasource healthy when scraped but Prometheus keeps restarting before the WAL fully loads
- Started after `serviceMonitorSelectorNilUsesHelmValues: false` enabled cluster-wide ServiceMonitor discovery, OR after a Velero restore exercise that left duplicate ServiceMonitors behind

**Root cause:**
The kube-prometheus-stack chart's default Prometheus memory limit is **1Gi**. That's insufficient on op-usxpress-dev once cluster-wide ServiceMonitor discovery picks up 30+ scrape targets — Prometheus OOMs during write-ahead-log replay before it can start the scrape loop. The pod restarts, WAL replays again, OOMs again — infinite loop.

Specifically observed when:
- Worker count >= 7 (each contributes a node-exporter + cAdvisor scrape target)
- ServiceMonitor cluster-wide discovery enabled
- Multiple Prometheus charts coexisting (a Velero restore-test ns left a duplicate KSM behind, tripling kube_node_info cardinality)

**IaC coverage:** ✓ (memory limit + cleanup of restore-test ns)

**IaC location:**
- `iaac-talos-flux-platform/infrastructure/prometheus/helmrelease.yaml` — set `values.prometheus.prometheusSpec.resources.limits.memory: 4Gi`

### Resolution via IaC

```yaml
# infrastructure/prometheus/helmrelease.yaml
spec:
  values:
    prometheus:
      prometheusSpec:
        resources:
          requests:
            cpu: 100m
            memory: 1Gi
          limits:
            cpu: 1000m
            memory: 4Gi   # was 1Gi — OOMs during WAL replay + scrape pool init
        serviceMonitorSelectorNilUsesHelmValues: false
```

PR: `variant-inc/iaac-talos-flux-platform` #69 (2026-06-24).

### Manual resolution / verification

```bash
# Confirm symptom
KCONFIG=~/.kube/op-usxpress-dev.yaml
kubectl --kubeconfig $KCONFIG -n prometheus get pods
kubectl --kubeconfig $KCONFIG -n prometheus describe pod prometheus-prometheus-stack-kube-prom-prometheus-0 | grep -A 2 "Last State"
# Look for: Reason: OOMKilled, Exit Code: 137

# Check current memory limit
kubectl --kubeconfig $KCONFIG -n prometheus get pod prometheus-prometheus-stack-kube-prom-prometheus-0 \
  -o jsonpath='prometheus_mem_limit={.spec.containers[?(@.name=="prometheus")].resources.limits.memory}{"\n"}'

# Verify no leftover restore-test ServiceMonitors inflating cardinality
kubectl --kubeconfig $KCONFIG get servicemonitor -A | grep restore-test
# If any appear, delete the leaked ns:
kubectl --kubeconfig $KCONFIG delete ns restore-test
```

### Related catalog entries

- `velero-restore-test-ns-sm-leak.md` — restore-test ns cleanup (contributing factor)
- `grafana-datasource-uid-mismatch.md` — common downstream symptom while Prometheus is unstable

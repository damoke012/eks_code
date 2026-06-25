# kube-prometheus-stack node-exporter pods Pending — hostPort 9100 already bound

**Symptom:**
- After installing or reconciling kube-prometheus-stack, node-exporter DaemonSet pods stay in `Pending` state
- `kubectl describe pod` on a Pending node-exporter shows:
  ```
  Warning  FailedScheduling  default-scheduler  0/10 nodes are available:
    1 node(s) didn't have free ports for the requested pod ports,
    9 node(s) didn't have free ports for the requested pod ports.
  ```
- `kubectl get pod -A -o wide | grep 9100` shows another DaemonSet already using port 9100 on the same workers

**Root cause:**
The kube-prometheus-stack chart's `prometheus-node-exporter` sub-chart defaults to `hostNetwork: true`, which means node-exporter binds host port 9100 directly on every worker. If ANY other chart on the cluster already deployed a node-exporter (e.g., a legacy `prometheus@29.x` install in a different namespace), the second DaemonSet can never schedule because port 9100 is taken.

Observed on op-usxpress-dev when:
- `risingwave-2` namespace runs its own `prometheus` chart with bundled node-exporter
- `monitoring` namespace also runs a legacy `prometheus` chart
- The new `prometheus` namespace (kube-prometheus-stack) tries to land its node-exporter on top

**IaC coverage:** ✓ (set `hostNetwork: false` on the kube-prometheus-stack copy)

**IaC location:**
- `iaac-talos-flux-platform/infrastructure/prometheus/helmrelease.yaml`

### Resolution via IaC

```yaml
# infrastructure/prometheus/helmrelease.yaml
spec:
  values:
    prometheus-node-exporter:
      hostNetwork: false              # bind pod IP, not host port 9100
      tolerations: []                 # do NOT tolerate CP NoSchedule taint
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: node-role.kubernetes.io/control-plane
                    operator: DoesNotExist
```

With `hostNetwork: false`:
- node-exporter listens on the pod IP, not the host
- Prometheus scrapes via cluster IP + Service
- Host `/proc`, `/sys`, `/` volume mounts still report host stats (network namespace doesn't affect volume mounts)
- Only `node_network_*` per-interface metrics get scoped to the pod namespace (acceptable trade-off)

PR: `variant-inc/iaac-talos-flux-platform` #66 (2026-06-24).

### Manual resolution / verification

```bash
# Confirm the symptom
KCONFIG=~/.kube/op-usxpress-dev.yaml
kubectl --kubeconfig $KCONFIG -n prometheus get pods -l app=prometheus-node-exporter

# Find who already owns port 9100
kubectl --kubeconfig $KCONFIG get pod -A -o wide | grep 9100
# (you should see another chart's node-exporter DaemonSet)

# After applying the IaC fix + reconcile, confirm pods Running
flux reconcile helmrelease prometheus-stack -n prometheus --force --with-source
kubectl --kubeconfig $KCONFIG -n prometheus get pods -l app=prometheus-node-exporter -w
```

### Long-term cleanup

Once the legacy `prometheus@29.x` installs in `risingwave-2/` and `monitoring/` are retired, the kube-prometheus-stack node-exporter can be flipped back to `hostNetwork: true` to recover full network-interface metrics.

### Related catalog entries

- `kube-prometheus-stack-memory-oom.md` — same chart, different symptom

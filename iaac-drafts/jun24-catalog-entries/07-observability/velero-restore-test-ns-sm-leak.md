# Velero restore-test namespace leaks ServiceMonitors → Prometheus duplicate scrape

**Symptom:**
- After a Velero restore exercise targeting a fresh namespace (e.g., `restore-test`), Prometheus shows duplicate metrics
- `count(kube_node_info)` returns 2-3× the actual node count
- Prometheus logs warn:
  ```
  err="out-of-order sample" series=... timestamp=...
  ```
- Grafana panels showing per-node aggregates have suspiciously high values
- Memory pressure on Prometheus pod (contributes to OOMKill from `kube-prometheus-stack-memory-oom.md`)

**Root cause:**
A Velero PVC backup is a snapshot of the namespace's full Kubernetes object set, including ServiceMonitors, PodMonitors, and any DaemonSets the source namespace's charts deployed. When restored to a fresh namespace name (`restore-test`), those objects come along — and once they exist, Prometheus's cluster-wide ServiceMonitor discovery (`serviceMonitorSelectorNilUsesHelmValues: false`) auto-picks them up as live scrape targets.

The result: multiple scrape targets for the same metrics (e.g., one kube-state-metrics per restored namespace × the count of source namespaces × replication factor), producing out-of-order sample errors and inflated cardinality.

**IaC coverage:** ✗ (operational hygiene — runbook discipline, not chart config)

This is a procedural gotcha — IaC can't prevent it because Velero restores are explicitly user-triggered with target namespace as a runtime parameter.

### Resolution — runbook step

After ANY `velero restore create` that targets a fresh namespace:

```bash
KCONFIG=~/.kube/op-usxpress-dev.yaml
RESTORE_NS=restore-test            # or whatever target you used

# 1. Validate the restore actually worked (pods Running, data accessible, etc.)
kubectl --kubeconfig $KCONFIG -n $RESTORE_NS get pods,pvc,sa

# 2. Record the verification in the restore-readiness ticket

# 3. DELETE the destination namespace
kubectl --kubeconfig $KCONFIG delete ns $RESTORE_NS --wait

# 4. Verify cleanup
kubectl --kubeconfig $KCONFIG get servicemonitor -A | grep $RESTORE_NS && echo "STILL LEAKING" || echo "clean"
```

### Detection (after the fact)

If you suspect a leak in an existing cluster:

```bash
KCONFIG=~/.kube/op-usxpress-dev.yaml

# List all ServiceMonitors and look for suspicious namespaces
kubectl --kubeconfig $KCONFIG get servicemonitor -A | grep -E "restore|test|backup"

# In Prometheus UI, run:
#   count by (__name__) ({__name__=~"kube_node_info"})
# A clean cluster returns count = number of nodes.
# A leaking cluster returns count = nodes * number of leaked KSM instances.
```

### Anti-pattern (do NOT do this)

- Do NOT scope the Velero restore to an existing namespace that has its own ServiceMonitors — you'll either fail (object name collisions) or worse, overlay broken state
- Do NOT leave the restore-test namespace running "for later" — every reconcile keeps the metric pollution active

### Related catalog entries

- `kube-prometheus-stack-memory-oom.md` — restore-test SM leak is a common contributor
- `velero-pvc-backup-runbook.md` — the proper restore exercise pattern

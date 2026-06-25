# Grafana dashboards show "No Data" — datasource UID mismatch

**Symptom:**
- Grafana panels render "No Data" across multiple dashboards
- Datasource page (Settings → Data sources → Prometheus) shows the datasource is healthy ("Working. Successfully queried the Prometheus API.")
- `kubectl logs` on Grafana shows no errors
- Browser DevTools network tab shows panel queries returning empty result sets
- Direct query in the Explore tab against the datasource works fine
- The datasource UID is something hashed like `PBFA97CFB590B2093`, NOT a human-readable string

**Root cause:**
Grafana auto-generates a hashed UID for any provisioned datasource that doesn't declare one explicitly. Dashboards (shipped as ConfigMaps) reference the datasource by UID — typically a human-readable string like `prometheus`. When the dashboard's UID reference doesn't match the auto-generated hash, the dashboard's panels silently resolve to "no datasource exists" and render empty.

Compounding gotcha: once a datasource exists with the wrong UID, **provisioning silently skips UID changes** on subsequent reconciles (Grafana treats UID as immutable). AND if `editable: false` is set on the datasource (recommended for IaC), the `DELETE /api/datasources/uid/<uid>` API returns `{"message":"Cannot delete read-only data source"}` — you can't even fix it via API.

The escape hatch is `deleteDatasources` in the provisioning YAML, which runs BEFORE the `datasources` block and bypasses the read-only flag.

**IaC coverage:** ✓ (UID pin + deleteDatasources block)

**IaC location:**
- `iaac-talos-flux-platform/infrastructure/grafana/helm-values-configmap.yaml`

### Resolution via IaC

```yaml
# helm-values-configmap.yaml — Grafana chart values
datasources:
  datasources.yaml:
    apiVersion: 1
    deleteDatasources:                # bypasses editable: false on UID reprovision
      - name: Prometheus
        orgId: 1
    datasources:
      - name: Prometheus
        uid: prometheus               # pin so dashboards' {uid:prometheus} resolve
        type: prometheus
        access: proxy
        url: http://prometheus-stack-kube-prom-prometheus.prometheus.svc.cluster.local:9090
        isDefault: true
        editable: false
```

`deleteDatasources` is idempotent — on subsequent reconciles when no UID mismatch exists, it's a no-op. Safe to leave in permanently.

PRs: `variant-inc/iaac-talos-flux-platform` #67 (UID pin) + #68 (deleteDatasources).

### Manual resolution / verification

```bash
# Confirm symptom by checking the current datasource UID
KCONFIG=~/.kube/op-usxpress-dev.yaml
GRAFANA_POD=$(kubectl --kubeconfig $KCONFIG -n grafana get pod -l app.kubernetes.io/name=grafana -o name | head -1)

# Get the datasource UID from the running config
kubectl --kubeconfig $KCONFIG -n grafana exec $GRAFANA_POD -c grafana -- \
  curl -s -u admin:admin http://localhost:3000/api/datasources/name/Prometheus | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print('uid:', d.get('uid'), 'editable:', d.get('readOnly'))"

# Expected: uid: prometheus, editable: True (readOnly: False)
# If uid is a hash like PBFA97CFB590B2093, you have this gotcha.
```

After applying the IaC fix, restart Grafana to force re-provisioning:

```bash
kubectl --kubeconfig $KCONFIG -n grafana rollout restart deployment grafana
```

### Anti-pattern (do NOT do this)

- Do not try to `kubectl exec` into Grafana and `DELETE /api/datasources/uid/<uid>` — `editable: false` blocks this
- Do not manually edit the provisioning YAML on the pod — it's a ConfigMap, will be reverted on next reconcile

### Related catalog entries

- `kube-prometheus-stack-memory-oom.md` — common upstream cause of "No Data" before reaching this gotcha

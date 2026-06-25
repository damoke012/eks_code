# Helm chart deployment stays at replicas=0 forever after PVC delete

**Symptom:**
- Following a manual storage class migration (e.g., `local-path` → `ceph-block`), the chart's deployment stays at `replicas: 0` indefinitely
- `kubectl get pvc -n <chart-ns>` shows the PVC is missing
- `flux reconcile helmrelease <name>` runs successfully but does not recreate the PVC
- `helm status <release>` shows `STATUS: deployed` — Helm thinks everything is fine
- The deployment YAML still references the (now-missing) PVC; no events about trying to recreate it

**Root cause:**
When a user (or operator) deletes a PVC that Helm originally created, Helm's drift detection does NOT auto-recreate it on the next upgrade or reconcile. Helm tracks resources by inclusion in the release's chart templates, not by ongoing state-compare. Specifically:

- If the chart creates the PVC as a separate Kubernetes object (NOT a StatefulSet `volumeClaimTemplate`), Helm treats it as "user owns the lifecycle"
- The chart's PVC manifest is rendered into the release, but Helm doesn't poll to ensure the in-cluster object still exists
- Next reconcile compares chart-source to release manifest — both still declare the PVC, so no diff, so nothing to do

This affects charts that create PVCs as standalone objects (Grafana, many database operators) — NOT charts that use `volumeClaimTemplate` inside a StatefulSet (Prometheus, PostgreSQL operator), where the StatefulSet controller auto-recreates the PVC on rebind.

**IaC coverage:** ✗ (procedural — IaC can't fix; needs runbook discipline)

### Resolution — manually apply the PVC with Helm adoption labels

When migrating storage class on an existing Helm release:

```bash
KCONFIG=~/.kube/op-usxpress-dev.yaml
RELEASE_NAME=grafana                    # the HelmRelease name
RELEASE_NS=grafana                      # the chart's namespace
PVC_NAME=grafana                        # whatever the PVC was called
NEW_STORAGE_CLASS=ceph-block
PVC_SIZE=10Gi

cat <<EOF | kubectl --kubeconfig $KCONFIG apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC_NAME
  namespace: $RELEASE_NS
  labels:
    app.kubernetes.io/instance: $RELEASE_NAME
    app.kubernetes.io/name: $RELEASE_NAME
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: $RELEASE_NAME
    meta.helm.sh/release-namespace: $RELEASE_NS
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: $NEW_STORAGE_CLASS
  resources:
    requests:
      storage: $PVC_SIZE
EOF

# Then force a Helm reconcile so Helm sees the PVC as "managed by me"
flux reconcile helmrelease $RELEASE_NAME -n $RELEASE_NS --force
```

The four label/annotation pairs (`app.kubernetes.io/managed-by: Helm`, `meta.helm.sh/release-name`, `meta.helm.sh/release-namespace`, `app.kubernetes.io/instance`) are what convince Helm the PVC is part of the release. Without them, the next chart upgrade may try to create its own PVC and conflict.

### Detection — confirm you have this gotcha

After a HelmRelease resume:

```bash
KCONFIG=~/.kube/op-usxpress-dev.yaml

# All three conditions must be true for this gotcha:
kubectl --kubeconfig $KCONFIG -n <ns> get deployment <name> -o jsonpath='{.status.replicas}{"\n"}'   # 0
kubectl --kubeconfig $KCONFIG -n <ns> get pvc                                                       # empty
helm --kubeconfig $KCONFIG -n <ns> status <release> | grep -i status                                # STATUS: deployed
```

If all three: the deployment is stuck because Helm thinks it's done; PVC was user-deleted; adoption labels are missing.

### Alternative — fresh-install path (doesn't have this gotcha)

For NEW clusters, ship the storage class change BEFORE the first install:

```yaml
spec:
  values:
    persistence:
      storageClassName: ceph-block    # set at install time, never deleted
      size: 10Gi
```

This gotcha ONLY bites on EXISTING installs where the PVC was manually deleted as part of a migration.

### Related catalog entries

- `local-path-helper-pod-namespace.md` — the storage class we're migrating AWAY from
- `rook-ceph-block-pvc-binding.md` — verifying ceph-block is healthy before the migration

# Local-Path PVC Stuck Pending (Helper Pod NS Issue)

**Symptom:**
- New PVC requesting `storageClassName: local-path` stays `Pending`
- `kubectl describe pvc <name>` shows: `waiting for first consumer to be created before binding`
- Even after a consuming pod is scheduled, PVC still Pending
- Local-path-provisioner logs show: `Failed to create helper pod`

**Root cause:**
Rancher `local-path-provisioner` spawns a transient "helper pod" to set up the host-path directory on the target node. By default, that helper pod runs in the `local-path-storage` namespace — NOT in the PVC's namespace.

If `local-path-storage` doesn't have permissive Pod Security label (default in restricted clusters denies privileged hostPath pods), the helper pod gets rejected, PVC binding fails.

**IaC coverage:** ✓ (label is in Flux manifest for the namespace)

**IaC location:**
- `iaac-talos-flux-platform/infrastructure/local-path-storage/namespace.yaml` — should have:
  ```yaml
  metadata:
    name: local-path-storage
    labels:
      pod-security.kubernetes.io/enforce: privileged
  ```

### Resolution via IaC

For fresh clusters: the namespace label is in the Flux manifest. Helper pods get scheduled. PVCs bind.

For ad-hoc clusters where the label is missing: add it to the Flux manifest, PR, merge.

### Manual resolution

**Step 1 — Confirm symptom:**

```bash
KCONFIG="--server=https://10.10.82.179:6443 --insecure-skip-tls-verify=true"

# PVC stuck
kubectl $KCONFIG -n <ns> get pvc <name>

# Check provisioner logs for helper pod errors
kubectl $KCONFIG -n local-path-storage logs -l app=local-path-provisioner --tail=30

# Check current namespace labels
kubectl $KCONFIG get namespace local-path-storage -o yaml | grep -A 3 labels
```

**Step 2 — Apply the label (manual fix):**

```bash
kubectl $KCONFIG label namespace local-path-storage \
  pod-security.kubernetes.io/enforce=privileged --overwrite
```

**Step 3 — Kick the provisioner to retry:**

```bash
kubectl $KCONFIG -n local-path-storage rollout restart deploy local-path-provisioner

# Wait, then verify PVC binds
sleep 30
kubectl $KCONFIG -n <ns> get pvc <name>
# Expect: STATUS=Bound
```

### Verification

```bash
# 1. PVC binds within 30s of consumer pod scheduling
kubectl $KCONFIG -n <ns> get pvc <name>
# Want: Bound

# 2. Helper pod scheduling succeeds (it's transient — finishes in seconds)
kubectl $KCONFIG -n local-path-storage get events --sort-by=.lastTimestamp | tail -10
```

### Prevention

- Label MUST be in the Flux-managed namespace manifest
- When Pod Security policy is `restricted` cluster-wide, ANY namespace that hosts privileged helper pods (local-path, csi drivers) needs explicit per-namespace exception

### Related

- [[../05-terraform-octopus/flux-prune-inventory-gotcha]] — if the namespace manifest is removed from Flux Kustomization, the live namespace gets deleted
- [[rook-mon-crashloop]] — mons use local-path PVCs; if local-path broken, mons can't start either

### Memory pointers

- `[local-path helper pod runs in local-path-storage ns]` — codified feedback memory

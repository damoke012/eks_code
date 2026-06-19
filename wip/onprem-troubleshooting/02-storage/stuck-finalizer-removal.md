# Stuck Finalizer — Resource Won't Delete

**Symptom:**
- `kubectl get <resource>` shows `STATUS=Terminating` for hours or days
- `kubectl get <resource> -o jsonpath='{.metadata.deletionTimestamp}'` shows a timestamp far in the past
- Operator that owns the resource can't recreate a fresh copy because the old one still exists
- `kubectl delete <resource>` hangs indefinitely

**Root cause:**
Kubernetes finalizers are a contract: "don't actually delete this resource until the controller named in the finalizer has cleaned up." If the controller is dead/broken/uninstalled, the resource is stuck in deletion limbo forever.

Common offenders on op-usxpress-dev:
- `ceph.rook.io/disaster-protection` on Rook ConfigMaps/Secrets (when operator can't reach mons to clean up)
- `kubernetes.io/pv-protection` on PVs/PVCs (when CSI driver gone)
- `argoproj.io/finalizer` on Argo resources (when controller deleted but resources remain)
- Custom finalizers from CRDs whose operators are uninstalled

**IaC coverage:** ❌ (no IaC; manual procedure only — but is safe)

**IaC location:** N/A — this is a corrective intervention, not preventive

### Resolution via IaC

None — finalizer state is inherent to k8s resource lifecycle. The "fix" is removing the finalizer field, which is always a manual interaction. No reasonable IaC for this.

### Manual resolution

**Step 1 — Identify the stuck resource + its finalizers:**

```bash
KCONFIG="--server=https://10.10.82.179:6443 --insecure-skip-tls-verify=true"

# Find resources stuck terminating in a namespace
NS=rook-ceph
kubectl $KCONFIG -n $NS get all,configmap,secret,pvc -o json | \
  jq -r '.items[] | select(.metadata.deletionTimestamp) | "\(.kind)/\(.metadata.name) — terminating since \(.metadata.deletionTimestamp), finalizers: \(.metadata.finalizers // [])"'

# OR for a specific resource you suspect
kubectl $KCONFIG -n $NS get configmap rook-ceph-mon-endpoints \
  -o jsonpath='{"deletionTimestamp: "}{.metadata.deletionTimestamp}{"\nfinalizers: "}{.metadata.finalizers}{"\n"}'
```

**Step 2 — Verify the owning controller is truly gone/broken:**

Before force-removing, check that the controller responsible CAN'T clean it up itself. If you remove the finalizer prematurely, the controller's cleanup logic never runs and you may leave orphan resources (e.g., disk space, AWS resources).

```bash
# Example: for ceph.rook.io/disaster-protection
kubectl $KCONFIG -n rook-ceph get pods -l app=rook-ceph-operator
# If operator Running but stuck → check operator logs for the cleanup attempt
kubectl $KCONFIG -n rook-ceph logs deploy/rook-ceph-operator --tail=100 | \
  grep -i "delete\|finalizer\|<resource-name>"
```

**Step 3 — Force-remove the finalizer (safe one-liner):**

```bash
NS=<namespace>
KIND=<kind>      # e.g., configmap, persistentvolume, secret
NAME=<name>

kubectl $KCONFIG -n $NS patch $KIND $NAME \
  -p '{"metadata":{"finalizers":null}}' --type=merge
```

The resource deletes immediately. For PersistentVolumes (cluster-scoped, no -n):

```bash
kubectl $KCONFIG patch pv $NAME -p '{"metadata":{"finalizers":null}}' --type=merge
```

**Step 4 — Verify deletion:**

```bash
kubectl $KCONFIG -n $NS get $KIND $NAME 2>&1
# Expect: Error from server (NotFound)
```

### Common cases on op-usxpress-dev

**Case A — Rook mon-endpoints ConfigMap stuck:**

```bash
kubectl $KCONFIG -n rook-ceph patch configmap rook-ceph-mon-endpoints \
  -p '{"metadata":{"finalizers":null}}' --type=merge
```

Operator immediately recreates a fresh `rook-ceph-mon-endpoints` once free to do so.

**Case B — Stuck namespace (won't terminate):**

Namespace has finalizer `kubernetes` and resources inside it are stuck. The namespace can't finish deleting until everything inside does.

```bash
# Find stuck resources in the namespace
NS=<stuck-ns>
kubectl $KCONFIG -n $NS get all,cm,secret,pvc -o json | \
  jq -r '.items[] | select(.metadata.deletionTimestamp) | "\(.kind)/\(.metadata.name)"'

# Force-clear finalizers on each one in turn
# Then namespace itself can finish terminating

# LAST RESORT — patch the namespace's own finalizers (very destructive)
kubectl $KCONFIG patch namespace $NS \
  -p '{"spec":{"finalizers":[]}}' --type=merge
```

Per [Confirm before executing] — clearing namespace finalizer is destructive. Only do this when 100% sure all owned resources are gone.

**Case C — PV stuck after PVC deleted:**

```bash
kubectl $KCONFIG patch pv <pv-name> -p '{"metadata":{"finalizers":null}}' --type=merge
```

Note: this leaves the underlying storage (Ceph image, local-path dir, etc.) orphaned. Clean it up manually.

### Verification

```bash
# Resource is gone
kubectl $KCONFIG -n $NS get $KIND $NAME 2>&1 | grep -q NotFound && echo "OK"

# Owning controller is happy (no error logs about the resource)
kubectl $KCONFIG -n <controller-ns> logs deploy/<controller> --tail=20 | \
  grep -i error
```

### Prevention

- Don't uninstall an operator before its managed resources are cleanly deleted
- When a Flux Kustomization is paused, its CRs may need explicit cleanup before kustomization deletion
- For Flux specifically: read [[../05-terraform-octopus/flux-prune-inventory-gotcha]] — removing a file from a `prune:true` Kustomization deletes the resource via inventory tracking; the finalizer scenario above is different (resource exists but won't terminate)

### Related

- [[rook-mon-crashloop]] — Rook's mon-endpoints CM is a common stuck-finalizer victim
- [[../05-terraform-octopus/flux-prune-inventory-gotcha]] — different but related deletion-semantics gotcha

### Memory pointers

- `[Session state Jun 19]` — `rook-ceph-mon-endpoints` stuck since `2026-06-17T16:22:04Z`
- `[Flux prune inventory gotcha]`

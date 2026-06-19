# Bitnami Chart NetworkPolicy Blocks Istio Ambient HBONE

**Symptom:**
- Workload deployed via Bitnami chart works internally (pod-to-pod within ns)
- Mesh clients (other namespaces using Istio ambient) get `connection reset by peer`
- Pod logs of the mesh client: `connect: connection refused on port 15008`
- Bitnami chart's `networkPolicy.enabled: true` (default) created a NetworkPolicy denying everything except the chart's app port

**Root cause:**
Bitnami charts create a default NetworkPolicy that allows only the configured app port (e.g., 5432 for postgres, 9092 for kafka). Istio ambient mode tunnels traffic through `15008` (HBONE secure overlay). The NetworkPolicy doesn't include 15008 → ambient mesh traffic is dropped silently.

**IaC coverage:** ✓ (codified workaround — disable Bitnami NP)

**IaC location:**
- Every Bitnami-chart HelmRelease in `iaac-talos-flux-platform/infrastructure/<workload>/`:
  ```yaml
  networkPolicy:
    enabled: false
  ```
- Plus: explicit manual delete of orphan NP (if the chart had `enabled: true` previously)

### Resolution via IaC

For fresh deploys: `networkPolicy.enabled: false` in values prevents the NP from being created.

For migrations: change values to `false`, reconcile, then delete the orphan NP that the chart left behind.

### Manual resolution

```bash
KCONFIG="--server=https://10.10.82.179:6443 --insecure-skip-tls-verify=true"

# Find the offending NetworkPolicy in the workload's namespace
NS=<workload-namespace>
kubectl $KCONFIG -n $NS get networkpolicy

# Inspect to confirm it's the Bitnami one (typical labels: app.kubernetes.io/instance, app.kubernetes.io/managed-by: Helm)
kubectl $KCONFIG -n $NS get networkpolicy <np-name> -o yaml | grep -A 10 spec

# DELETE the orphan NP (after updating HelmRelease values to disable)
kubectl $KCONFIG -n $NS delete networkpolicy <np-name>

# Confirm Bitnami chart's HelmRelease has networkPolicy.enabled: false
kubectl $KCONFIG -n flux-system get helmrelease <name> -o yaml | \
  grep -A 2 networkPolicy
```

### Verification

```bash
# 1. NP gone
kubectl $KCONFIG -n <ns> get networkpolicy
# Expect: no Bitnami NP listed

# 2. Mesh client can reach workload via HBONE
kubectl $KCONFIG -n <client-ns> exec deploy/<client> -- \
  curl -sv http://<workload>.<workload-ns>.svc:<port>
# Expect: successful connection (not "connection reset by peer")

# 3. Istio waypoint sees the traffic
istioctl pc cluster <client-pod> -n <client-ns> | grep <workload>
# Expect: HBONE cluster entry
```

### Prevention

- Code review: ANY Bitnami chart HelmRelease MUST have `networkPolicy.enabled: false`
- Lint script (planned): scan HelmRelease values for `networkPolicy.enabled: true`, reject with explanation
- Document in onboarding: "if you're using a Bitnami chart, the default NP is broken in ambient mesh"

### Related

- [[../06-incidents-timeline/2026-06-19-dns-irsa-rw-cascade]] — RW namespace has Bitnami chart for postgres + we hit this earlier
- [[istio-cni-ztunnel-stale]] — separate symptom, also affects ambient traffic
- Memory: `[Bitnami chart NP blocks ambient HBONE]`

### Memory pointers

- `[feedback_bitnami_chart_np_ambient_hbone]` — codified gotcha
- `[Bitnami removed versioned tags]` — separate but related Bitnami issue (image tags moved to bitnamilegacy)

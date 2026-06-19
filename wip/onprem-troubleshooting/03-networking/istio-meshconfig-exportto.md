# Istio MeshConfig defaultServiceExportTo Hides Services from Ingress

**Symptom:**
- Workloads behind the shared Istio ingress (`shared-http` Gateway) return `503 Service Unavailable` or `no healthy upstream`
- Dashboard URLs like `https://dashboard.<env>.usxpress.io` return 503
- TCP-passthrough listeners (e.g., `rw2-sql.op-dev.usxpress.io:5432`) work fine — only HTTP routing affected
- `istioctl pc cluster <ingress-pod>` does NOT list the destination service

**Root cause:**
MeshConfig has `defaultServiceExportTo`, `defaultVirtualServiceExportTo`, and `defaultDestinationRuleExportTo` keys. If any of these is set to `["."]` (current namespace only), Services in other namespaces are HIDDEN from sidecars/gateways outside their own namespace.

The ingress gateway (`istio-ingress` namespace) needs to see Services in `dashboard`, `risingwave`, etc. With `defaultServiceExportTo: ["."]`, it sees only services in `istio-ingress`. Routing fails silently.

**IaC coverage:** ✓ (codified — `defaultServiceExportTo: ["*"]` in iaac-talos-flux-platform op-dev)

**IaC location:**
- `iaac-talos-flux-platform/infrastructure/istio/istiod/values.yaml` — should have:
  ```yaml
  meshConfig:
    defaultServiceExportTo: ["*"]
    defaultVirtualServiceExportTo: ["*"]
    defaultDestinationRuleExportTo: ["*"]
  ```
- Codification status: validated end-to-end on op-usxpress-dev 2026-06-02; codification was pending then — check current state of values.yaml

### Resolution via IaC

Once the values.yaml has the correct exportTo configuration, every Service is visible to the ingress gateway. No manual intervention needed for fresh deploys.

### Manual resolution (if values.yaml drifted)

```bash
KCONFIG="--server=https://10.10.82.179:6443 --insecure-skip-tls-verify=true"

# Confirm symptom
istioctl pc cluster <ingress-pod-name> -n istio-ingress | grep -i <expected-service>
# If missing → MeshConfig is hiding it

# Check current MeshConfig
kubectl $KCONFIG -n istio-system get configmap istio -o yaml | grep -A 5 "defaultServiceExportTo\|defaultVirtualServiceExportTo\|defaultDestinationRuleExportTo"

# Patch the MeshConfig live (TEMPORARY until Flux reconciles correct value)
kubectl $KCONFIG -n istio-system patch configmap istio --type=merge -p '{"data":{"mesh":"defaultServiceExportTo: [\"*\"]\ndefaultVirtualServiceExportTo: [\"*\"]\ndefaultDestinationRuleExportTo: [\"*\"]\n"}}'

# Restart istiod to pick up new MeshConfig
kubectl $KCONFIG -n istio-system rollout restart deploy istiod

# Restart the ingress gateway to receive new xDS config
kubectl $KCONFIG -n istio-ingress rollout restart deploy istio-ingress
```

### Verification

```bash
# 1. Destination service appears in ingress pod's cluster list
INGRESS_POD=$(kubectl $KCONFIG -n istio-ingress get pod -l app=istio-ingress -o jsonpath='{.items[0].metadata.name}')
istioctl pc cluster $INGRESS_POD -n istio-ingress | grep -i <expected-service>
# Expect: cluster entry shown

# 2. HTTP route works end-to-end
curl -sk https://<dashboard-or-app>.op-dev.usxpress.io -o /dev/null -w "HTTP %{http_code}\n"
# Expect: HTTP 200 or 302
```

### Prevention

- The values.yaml MUST set the three `default*ExportTo: ["*"]` keys. Code review any Istio HelmRelease changes for this.
- Service-level `exportTo` overrides default but is rarely set. Don't rely on it.
- For namespace-scoped scoping (rare need), use `serviceScopeConfigs` instead — explicit, audit-friendly.

### Related

- [[../../iac-sweep-jun18/track1-istio-resilience/]] — Track 1 covers istiod resilience
- Memory: `[Istio MeshConfig exportTo RCA]` — full RCA from 2026-06-02

### Memory pointers

- `[Istio MeshConfig exportTo RCA — 2026-06-02]` — TRUE RCA for dashboard 503; supersedes earlier waypoint diagnosis in session_state_jun01_pm
- `[Per-team cert pattern for HTTPS plane]` — shared-http Gateway pattern that this MeshConfig enables

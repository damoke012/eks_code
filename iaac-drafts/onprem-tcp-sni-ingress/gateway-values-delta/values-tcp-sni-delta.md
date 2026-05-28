# Delta to `istio-ingressgateway-values` ConfigMap

**Repo:** `iaac-talos-flux-platform`, branch `op-dev`
**Path:** `infrastructure/istio-ingress/values.yaml` (the ConfigMap data)
**Note:** Current live values use **hostPort + DaemonSet** (per `wip/onprem-networking/STATE.md`; the `iaac-drafts/onprem-istio-ingress/...values.yaml` snapshot is the older hostNetwork=true draft and is now stale. Re-pull live before editing.)

## What to add

Two `Service.ports` entries (+ optionally health probe ports) and two `containerPorts`. Below is the YAML fragment to insert into the existing values. Names follow the istio convention of `tls-passthrough-<protocol>`:

```yaml
# In the chart values for istio-ingress gateway DaemonSet:

service:
  # NOTE: with hostPort DaemonSet the Service is mainly for selectors and
  # mesh-internal access. The actual external listener is the worker's
  # hostPort. Keep the Service ports in sync so Gateway/VirtualService
  # selectors resolve.
  type: ClusterIP
  ports:
  - name: status-port
    port: 15021
    targetPort: 15021
  - name: http2
    port: 80
    targetPort: 80
  - name: https
    port: 443
    targetPort: 443
  # --- NEW: TLS-PT TCP listeners ---
  - name: tls-passthrough-rwsql
    port: 4567
    targetPort: 4567
  - name: tls-passthrough-postgres
    port: 5432
    targetPort: 5432

# Container-side hostPorts so each worker NIC binds these ports too.
# This block depends on chart version — current chart's path for
# adding hostPorts to the gateway container is `containerPorts`.
# Reference upstream values.yaml of the istio/gateway chart for the exact key.
containerPorts:
- containerPort: 15021
  name: status-port
  hostPort: 15021
- containerPort: 80
  name: http2
  hostPort: 80
- containerPort: 443
  name: https
  hostPort: 443
# --- NEW ---
- containerPort: 4567
  name: rwsql
  hostPort: 4567
- containerPort: 5432
  name: postgres
  hostPort: 5432
```

## Pre-flight (CRITICAL — run before merging)

```bash
# On each worker, confirm 4567 and 5432 are free
for n in op-usxpress-dev-w-{0..6}; do
  echo "=== $n ==="
  kubectl debug node/$n --image=busybox -- nsenter -t 1 -n ss -lntp 2>/dev/null \
    | grep -E ':(4567|5432) '
done
# Expect no output. If any worker has a listener, STOP and investigate.
```

## Rolling restart strategy

DaemonSet update strategy is already `RollingUpdate` (chart default). After
the ConfigMap change merges, the DaemonSet observes the new values; pods
roll one at a time. Watch for: NodeNotReady triggers, hostPort bind errors,
listener bind conflicts on workers.

```bash
kubectl -n istio-ingress rollout status ds/istio-ingressgateway
kubectl -n istio-ingress get pods -o wide
```

If a pod fails to bind a hostPort, it crashloops — revert the ConfigMap.

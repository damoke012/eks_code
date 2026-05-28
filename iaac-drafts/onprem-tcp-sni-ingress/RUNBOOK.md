# Phase 1 — Istio Gateway TCP listeners + SNI passthrough RUNBOOK

**Ticket:** INFRA-1494 (sub-task of [INFRA-1492](https://usxpress.atlassian.net/browse/INFRA-1492))
**Design:** [`docs/designs/tcp-sni-ingress-design.md`](../../docs/designs/tcp-sni-ingress-design.md)
**Depends on:** Phase 0 (INFRA-1493) — cert-manager + wildcard cert. **Listener can be added before Phase 2** (backend TLS); SNI routes correctly but the backend will RST until TLS is enabled.

---

## Pre-flight (WSL, codespace can't reach cluster)

```bash
# 1. RW protection check — workload must be Running before any change
kubectl get rw -n risingwave -o wide
kubectl get rw -n risingwave-2 -o wide
# Expect: Running=True on both. If not, STOP.

# 2. Worker port availability — 4567 and 5432 must be FREE on every worker
for n in $(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name); do
  echo "=== $n ==="
  kubectl debug $n --image=busybox -- nsenter -t 1 -n ss -lntp 2>/dev/null \
    | grep -E ':(4567|5432) '
done
# Expect: NO matches. If any worker has these bound, STOP and investigate.

# 3. Gateway DaemonSet current state
kubectl -n istio-ingress get ds istio-ingressgateway
kubectl -n istio-ingress get pods -o wide
# Expect: pod count == worker count; all Ready.
```

## Step 1 — Extend gateway DaemonSet values

`gateway-values-delta/values-tcp-sni-delta.md` describes the YAML edits to
the live values ConfigMap (in `iaac-talos-flux-platform`, branch `op-dev`,
path `infrastructure/istio-ingress/values.yaml`).

**Author the PR carefully**:
1. **Pull the LIVE values file** first — the local `iaac-drafts/onprem-istio-ingress/...values.yaml` is the older hostNetwork=true draft, NOT what's running. The live values use **hostPort + DaemonSet**.
2. Add the new `service.ports` entries and `containerPorts` entries per the delta.
3. PR to `op-dev`. Squash-merge.
4. `flux reconcile source git infra && flux reconcile helmrelease -n istio-ingress istio-ingressgateway` (or whatever the chart resource is named).

Watch the rollout:

```bash
kubectl -n istio-ingress rollout status ds/istio-ingressgateway --timeout=10m

# Spot-check Envoy listener config on one pod
P=$(kubectl -n istio-ingress get pods -l istio=ingressgateway -o jsonpath='{.items[0].metadata.name}')
kubectl -n istio-ingress exec $P -- curl -s localhost:15000/listeners | grep -E '4567|5432'
# Expect: lines mentioning the new listeners after Gateway resource is applied.
```

## Step 2 — Apply Gateway + VirtualService resources

```bash
kubectl apply -f gateway-resources/tcp-passthrough-gateway.yaml
kubectl apply -f virtualservices/rw2-sql-passthrough.yaml
# (Hold off on rw2-pg-passthrough.yaml until you confirm postgres exposure is wanted)
```

Verify Istio accepted the resources:

```bash
kubectl -n istio-ingress get gateway tcp-passthrough -o yaml | grep -A3 status
kubectl -n istio-ingress get virtualservice rw2-sql-passthrough -o yaml | grep -A3 status

# istioctl analyze flags config errors:
istioctl analyze -n istio-ingress
```

## Step 3 — DNS propagation

If the Gateway / VS annotations + external-dns are correctly wired,
external-dns should create A-records pointing at the worker IPs:

```bash
# Watch external-dns logs for the new record creation
kubectl -n external-dns logs -l app.kubernetes.io/name=external-dns --tail=50 \
  | grep rw2-sql

# Verify DNS from corp VPN (NOT codespace — codespace doesn't have on-prem DNS)
dig +short rw2-sql.op-dev.usxpress.io
# Expect: list of worker IPs (10.10.82.x), round-robin order.
```

If external-dns doesn't pick up the Gateway/VirtualService, fall back to a
manual A-record annotation or temporary static record. Don't block on it.

## Step 4 — Validate SNI route WITHOUT backend TLS (Listener-level test)

Before Phase 2 lights up backend TLS, you can prove the gateway listener
and SNI route are wired by attempting a TLS handshake:

```bash
# From corp VPN (NOT codespace)
openssl s_client -servername rw2-sql.op-dev.usxpress.io \
  -connect rw2-sql.op-dev.usxpress.io:4567 \
  -showcerts < /dev/null 2>&1 | head -30
# Expected output (until Phase 2):
#   ... `:errno=104 Connection reset by peer` or similar — gateway received
#   ClientHello, attempted to proxy to backend, backend RST because it
#   doesn't speak TLS yet. This is GOOD — proves listener + route are right.
#
# If you get "connection refused" instead, the listener isn't bound — go
# back to Step 1 pre-flight and Envoy listener spot-check.
```

## Step 5 — Validate end-to-end (post Phase 2)

ONLY after INFRA-1495 lights up backend TLS on RW-2 frontend:

```bash
psql 'host=rw2-sql.op-dev.usxpress.io port=4567 sslmode=require dbname=dev user=...'
\conninfo
# Expect: connected via TLS.
```

## Rollback (per failure mode)

| Failure | Rollback |
|---|---|
| DaemonSet pod fails to bind hostPort 4567/5432 | Revert ConfigMap PR; Flux + DS rolls back. RW unaffected — TCP listener is purely additive. |
| Envoy listener config error (istioctl analyze flags) | Delete Gateway/VirtualService (`kubectl delete -f ...`); no impact on existing HTTP plane. |
| external-dns doesn't create records | Manually add A-records in Route53 (via WSL with `aws-vault` or similar) as a stopgap; investigate external-dns Gateway source separately. |
| SNI routes to wrong backend | Edit VirtualService `tls.match.sniHosts` or `destination.host`; reapply. Stateless change. |

## Success criteria for INFRA-1494 closure

- [ ] DaemonSet pods Running on all workers after rollout; 4567 + 5432 bound on each worker IP
- [ ] `Gateway tcp-passthrough` and `VirtualService rw2-sql-passthrough` accepted by Istio
- [ ] DNS `rw2-sql.op-dev.usxpress.io` resolves to worker IPs (round-robin)
- [ ] Listener-level TLS handshake test (Step 4) reproducible — gateway receives ClientHello and proxies
- [ ] RW namespaces (both `risingwave` and `risingwave-2`) Running=True before AND after
- [ ] PR squash-merged on `op-dev` (iaac-talos-flux-platform)
- [ ] No regression to existing HTTP plane — `api.brands.dev.usxpress.io` still 404s from Envoy (or whatever the previous baseline was)

## After closure

INFRA-1495 (Phase 2) is unblocked — backend TLS on `risingwave-2` then `risingwave`.

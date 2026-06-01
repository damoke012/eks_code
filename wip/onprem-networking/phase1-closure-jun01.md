# Phase 1 (INFRA-1494) — TCP/SNI listeners CLOSED 2026-06-01

## Verdict

End-to-end TCP/SNI ingress plane works on op-usxpress-dev. Phase 2 (INFRA-1495 — backend TLS on RW-2 frontend) is now unblocked.

## What landed

| | PR | Repo / Branch | What it added |
|---|---|---|---|
| 1 | [#13](https://github.com/variant-inc/iaac-talos-flux-platform/pull/13) | iaac-talos-flux-platform op-dev | TCP listeners 4567 + 5432 on `istio-ingressgateway` DaemonSet via postRenderer kustomize patches (mirrors existing 80/443 pattern) |
| 2 | [#14](https://github.com/variant-inc/iaac-talos-flux-platform/pull/14) | iaac-talos-flux-platform op-dev | Added `istio-virtualservice` to external-dns sources so VS annotations get A-records |

Plus two kubectl-applied resources (NOT yet in GitOps source — see follow-ups):
- `Gateway istio-ingress/tcp-passthrough` — TLS-PASSTHROUGH servers on 4567 + 5432
- `VirtualService istio-ingress/rw2-sql-passthrough` — SNI `rw2-sql.op-dev.usxpress.io` → `risingwave-frontend.risingwave-2.svc:4567`

And one runtime annotation:
- `external-dns.alpha.kubernetes.io/target` on the VS — explicit list of all 7 worker IPs (because the gateway Service is ClusterIP, not LB; external-dns can't auto-derive)

## Verification evidence

| Layer | Probe | Result |
|---|---|---|
| **DaemonSet spec** | `kubectl get ds ... -o jsonpath='...ports[*]'` | Shows `rwsql=4567/TCP (host=4567)`, `postgres=5432/TCP (host=5432)` |
| **HostPort claims** | `kubectl get pods -n istio-ingress -o json \| jq '...hostPort==4567 or ==5432'` | 14 lines (7 workers × 2 ports) |
| **Envoy listener** | `pilot-agent request GET listeners` from gateway pod | `0.0.0.0_4567::0.0.0.0:4567` present |
| **DNS A-record** | external-dns logs | `INSERT dynamodb record "rw2-sql.op-dev.usxpress.io#A#"` + Route53 CREATE confirmed |
| **DNS resolution from corp VPN** | `getent hosts rw2-sql.op-dev.usxpress.io` | Returns all 7 worker IPs round-robin |
| **TCP + SNI from corp VPN** | `openssl s_client -servername rw2-sql.op-dev.usxpress.io -connect ...:4567` | `CONNECTED(...)` + ClientHello written (328 bytes) + `write:errno=104` from backend (expected pre-Phase-2) |
| **Tim RW protection** | `kubectl get rw -n risingwave-2` | Running=True before AND after (`risingwave` ns is Idris's track) |

## Key gotchas captured (for next time / for QA promotion)

### 1. external-dns istio-virtualservice source is NOT default
The existing `istio-gateway` source watches Gateway resources but can't expand wildcard hosts (`*.op-dev.usxpress.io`) into A-records. Adding `istio-virtualservice` was a one-line PR but required for per-VS hostname publication.

### 2. external-dns can't auto-derive targets when the Service is ClusterIP
The on-prem gateway uses **hostPort + ClusterIP Service** (not LoadBalancer), so external-dns has no external IPs to put in the A-record. Workaround: explicit `external-dns.alpha.kubernetes.io/target` annotation. Per-VS annotation is what we did; per-Gateway or `--default-targets` would scale better.

### 3. The `kubectl debug --profile=netadmin` probe doesn't work on Talos
Pre-flight port-checking needs a `hostNetwork: true` pod with `ss` inside, because Talos blocks `nsenter -t 1 -n`. We had to switch probes mid-pre-flight.

### 4. hostPort uses portmap CNI (iptables NAT), not a userspace listener
`ss -lntp` in a host-netns pod does NOT show hostPort bindings — only the actual kube/portmap rules do. Use `kubectl get pods -o json | jq '...hostPort'` for the authoritative check. The "NOT BOUND" false alarm threw us once; documenting so we don't repeat.

### 5. istioctl wasn't installed on WSL
Workaround: `pilot-agent request GET listeners` directly via `kubectl exec` into a gateway pod. Same data, no extra tool needed. Worth installing istioctl later for cleaner output.

### 6. Idris's PR #7 merge broke Tim's RW (parallel track — NOT Phase 1)
During Phase 1 work, Tim's `risingwave` ns went Running=False due to `risingwave-pg-credentials` Secret missing after Idris's source took over GitOps management. Per track-separation rule, we kept hands off; Idris is fixing in his repo.

## Follow-ups (file as sub-tasks under INFRA-1492 if not done)

1. **Persist Gateway + VirtualService to iaac-talos-flux-platform source** — they're applied via kubectl right now; should be in `infrastructure/istio-ingress/` so they reconcile via Flux.
2. **Move target annotation off per-VS** — either onto the shared `tcp-passthrough` Gateway (cleaner) OR set `--default-targets` on external-dns (cleanest). Doke owns. Small.
3. **Add `postgres` VS template** — currently only `rwsql` (4567) has a VS. When Phase 2 lands a postgres backend, add `rw2-pg-passthrough` analogous to `rw2-sql-passthrough` on port 5432.
4. **Phase 2 (INFRA-1495)** — backend TLS on RW-2 frontend so the openssl test completes with a real handshake instead of RST.

## Tickets state

- ✅ INFRA-1494 **Done** (Phase 1)
- ⏳ INFRA-1492 (TCP/SNI umbrella) — Phase 1 closed, Phase 2 next
- ⏳ INFRA-1495 (Phase 2 — backend TLS) — unblocked, not yet started
- ⏳ INFRA-1496 (Phase 3 — NetworkPolicy + CIDR) — still gated on Steve Duck CIDR list
- ⏳ INFRA-1497 (Phase 4 — audit + monitoring) — still gated on Steve Vives audit destination
- ⏳ INFRA-1502 (LE auto-rotation) — parallel
- ⏳ INFRA-1503 (Prometheus expiry alerts) — parallel
- ⏳ INFRA-1504 (CAA record) — gated on Duck registrar check

## Commands log (for re-running on QA/PROD)

```bash
# Pre-flight (run before any change)
kubectl get rw -A    # both ns Running=True
kubectl get pods -A -o json | jq '.items[] | .spec.containers[]?.ports[]? | select(.hostPort == 4567 or .hostPort == 5432) | "claim found"'
kubectl -n istio-ingress get ds istio-ingressgateway

# Step 1 — DaemonSet listeners (Flux PR pattern)
# Edit: infrastructure/istio-ingress/values.yaml (add to service.ports)
# Edit: infrastructure/istio-ingress/release.yaml (add 2 postRenderer patch ops)
# Squash-merge → Flux reconcile → DS rolling restart

# Step 2 — Gateway + VirtualService (kubectl apply OR Flux source)
kubectl apply -f gateway-resources/tcp-passthrough-gateway.yaml
kubectl apply -f virtualservices/rw2-sql-passthrough.yaml

# Step 3 — DNS (one-time external-dns config + per-VS target)
# PR external-dns sources adds `istio-virtualservice`
# Annotate each VS with target=<worker-ips-csv>

# Step 4 — Smoke (from corp VPN)
openssl s_client -servername rw2-sql.op-dev.usxpress.io -connect rw2-sql.op-dev.usxpress.io:4567 </dev/null 2>&1 | head -25
# Expected: CONNECTED + write:errno=104 (gateway accepted, backend RST = good pre-Phase-2)
```

# TCP/SNI passthrough ingress on-prem IaC draft (Phase 1)

**Jira:** [INFRA-1494](https://usxpress.atlassian.net/browse/INFRA-1494) (sub-task of [INFRA-1492](https://usxpress.atlassian.net/browse/INFRA-1492))
**Design:** [`docs/designs/tcp-sni-ingress-design.md`](../../docs/designs/tcp-sni-ingress-design.md)
**Runbook:** [`RUNBOOK.md`](./RUNBOOK.md)
**Depends on:** Phase 0 cert-manager + wildcard cert (INFRA-1493). Listener may go in before backends have TLS — by design SNI route is wired but backend RSTs until Phase 2 (INFRA-1495).

## What this directory contains

```
gateway-values-delta/
  values-tcp-sni-delta.md    → describes the YAML edits to the
                               live `istio-ingressgateway-values`
                               ConfigMap (do NOT replace; merge)
gateway-resources/
  tcp-passthrough-gateway.yaml → Istio Gateway with TLS-PASSTHROUGH
                                 listeners on 4567 + 5432
virtualservices/
  rw2-sql-passthrough.yaml   → SNI route to RW-2 frontend
  rw2-pg-passthrough.yaml    → SNI route to RW-2 postgres meta
                               (optional — hold until needed)
RUNBOOK.md                   → apply order, smoke tests, rollback
```

## Target repos

| Repo | Branch | Files |
|---|---|---|
| `variant-inc/iaac-talos-flux-platform` | `op-dev` | edit `infrastructure/istio-ingress/values.yaml` per the delta; place new Gateway + VirtualService manifests under `infrastructure/istio-ingress/` (or wherever the chart picks up extra resources) |

The Gateway + VirtualService can also be **hand-applied** for the first iteration if you want to keep the merge surface small (Flux will adopt them on next reconcile if the manifests are also committed).

## Design choices

| | |
|---|---|
| **Mode** | TLS PASSTHROUGH (Envoy peeks SNI in ClientHello, proxies bytes) |
| **Ports** | 4567 (RW SQL), 5432 (postgres) — extend per-protocol as new backends come |
| **Routing key** | SNI hostname (`*.op-dev.usxpress.io`) — single port can fan out across many backends |
| **Cert authority** | Backend pods serve TLS using cert-manager-issued certs (Phase 2) |
| **Reachability** | hostPort DaemonSet on every worker; DNS round-robins to worker IPs |
| **External-DNS** | Per-Gateway / per-VirtualService annotation creates A-records |
| **Source allow-list** | NOT here — that's Phase 3 (CiliumNetworkPolicy, INFRA-1496) |

## Why this pattern is prod-grade

See [`docs/designs/tcp-sni-ingress-design.md`](../../docs/designs/tcp-sni-ingress-design.md). Summary:

- One control plane (Istio), one cert chain (cert-manager), one DNS (external-dns).
- Reuses the existing gateway DaemonSet — no new operational surface.
- TLS PASSTHROUGH means clients negotiate native protocol TLS with the backend; no double-handshake.
- SNI routing scales: many backends per port, hostname-based fan-out (same UX as HTTP DNS).
- Carries to QA/PROD on-prem clusters unchanged — only DNS zone and cert source change.

## Constraints respected

- **Additive** — does NOT modify any existing HTTP/HTTPS listener or VirtualService.
- **Pre-flight pod-port collision check** in RUNBOOK before hostPort changes.
- **RW protection** — pre/post checks for `risingwave` and `risingwave-2` Running=True.
- **No AI attribution** in commits/PRs.
- Single-PR-per-repo scope; reviewable change.

## Validation paths

| What | How |
|---|---|
| Listener bound on every worker | `ss -lntp` on each worker (Step 1 of RUNBOOK) |
| Envoy accepted listener | `curl localhost:15000/listeners` on a gateway pod |
| Gateway/VirtualService accepted by Istio | `istioctl analyze` |
| DNS resolves | `dig +short rw2-sql.op-dev.usxpress.io` from VPN |
| SNI route wired (pre Phase 2) | `openssl s_client -servername ...` — expect Connection reset (backend doesn't speak TLS yet) |
| End-to-end (post Phase 2) | `psql 'host=rw2-sql.op-dev.usxpress.io port=4567 sslmode=require'` |

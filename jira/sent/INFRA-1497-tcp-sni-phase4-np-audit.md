---
key: INFRA-1497
status: filed
assignee: Doke
reporter: Doke
created: 2026-05-28
initiative: onprem-networking
labels: [onprem, networking, security, audit, observability, phase4]
issuetype: Sub-task
parent: INFRA-1492
---

# Phase 4 — Backend NetworkPolicy + audit logging

## Context
Defense in depth: even if the gateway CIDR allow-list (Phase 3) is bypassed, backend Services should only accept traffic from gateway DaemonSet pods. Plus app-layer audit (pgaudit on postgres, RW audit if available) for traceability.

## Scope

**In:**
- `NetworkPolicy` in `risingwave-2` ns: ingress to backend Services only from `istio-ingress` ns gateway pods (namespace+pod selector).
- Enable `pgaudit` on postgres-postgresql (chart values).
- Verify Envoy access log per TCP session flows to existing log shipping (stdout → log collector).
- Document the per-namespace backend NP template for app teams.

**Out:**
- Centralized log alerting (separate observability ticket).
- RW-internal audit (separate, if RW exposes it).

## Definition of done
- [ ] NetworkPolicy applied; unauthorized cross-namespace probe fails
- [ ] Authorized gateway-via path succeeds (regression of Phase 2 end-to-end)
- [ ] pgaudit logs visible in postgres pod logs OR forwarded to log store
- [ ] Envoy TCP session access log entries visible per connection
- [ ] Pattern documented in `iaac-drafts/onprem-tcp-sni/` as the per-service NP template

## Suggested approach
1. **Author backend NetworkPolicy** with namespace selector matching `istio-ingress` + pod selector on `istio: ingressgateway`.
2. **Test negatively** from a different ns first: `kubectl run -n default test --image=postgres:15 -- psql ...` should fail.
3. **Test positively** via the gateway path (Phase 2 regression).
4. **Enable pgaudit** in postgres-postgresql values; verify a log line per SQL command at the configured level.
5. **Envoy access log** — confirm format includes source IP, SNI, bytes, duration.

## Constraints
- Don't break in-cluster gossip / mesh traffic when adding the NP — default-deny needs careful ingress rules.
- pgaudit verbosity tuning: too verbose floods logs.

## Links
- Parent: [TCP/SNI ingress umbrella]
- Design doc: [`docs/designs/tcp-sni-ingress-design.md#phase-4`](https://github.com/damoke012/eks_code/blob/main/docs/designs/tcp-sni-ingress-design.md)

## Estimate
S — NP is a small resource; pgaudit + audit log validation modest.

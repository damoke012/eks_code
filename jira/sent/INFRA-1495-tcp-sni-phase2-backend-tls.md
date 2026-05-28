---
key: INFRA-1495
status: filed
assignee: Doke
reporter: Doke
created: 2026-05-28
initiative: onprem-networking
labels: [onprem, networking, tls, risingwave, postgres, phase2]
issuetype: Sub-task
parent: INFRA-1492
---

# Phase 2 — Backend TLS enablement (`risingwave-2` first, then `risingwave`)

## Context
SNI passthrough at the gateway means the backend pod terminates TLS itself. Each backend needs a cert (from cert-manager Phase 0) and TLS enabled in its chart values.

**Start with `risingwave-2`** (Doke-owned IaC pattern, low risk). Defer `risingwave` until Idris has anchored it to Flux (INFRA-1487) — touching that namespace requires Tim coord per `feedback_protect_rw_onprem_workload`.

## Scope

**In:**
- cert-manager `Certificate` resources in `risingwave-2` ns for `rw2-sql.op-dev.usxpress.io` (frontend) and `rw2-pg.op-dev.usxpress.io` (postgres meta).
- Enable TLS on `iaac-risingwave-2` HelmRelease values (RW frontend + postgres-postgresql chart).
- Verify TLS handshake from in-cluster client (`psql sslmode=require` via port-forward) BEFORE wiring through gateway.
- Document the per-service onboarding pattern (basis for Phase 5 runbook).

**Out:**
- `risingwave` namespace TLS work — separate ticket once INFRA-1487 (Flux anchoring) closes.
- mTLS at the gateway (deferred per design doc §"Open question").
- Any chart upstream patches — if chart can't enable TLS via values, fork/upstream PR is a separate ticket.

## Definition of done
- [ ] `Certificate risingwave-2/rw2-sql-tls` Ready=True with cert mounted in RW frontend pod
- [ ] `Certificate risingwave-2/rw2-pg-tls` Ready=True with cert mounted in postgres pod
- [ ] RW frontend listens on TLS port; in-cluster `psql 'host=risingwave-frontend.risingwave-2.svc port=4567 sslmode=require'` succeeds
- [ ] Postgres TLS verified: `psql 'host=postgres-postgresql.risingwave-2.svc port=5432 sslmode=require'`
- [ ] Pods restart cleanly; no CrashLoop
- [ ] (After Phase 1) external `psql` from corp VPN via `rw2-sql.op-dev.usxpress.io:4567 sslmode=require` succeeds end-to-end

## Suggested approach
1. **Inspect chart values** for RW + postgres-postgresql to confirm TLS-enable flags + existingSecret pattern.
2. **Issue certs first** (cert-manager Certificate resources) — verify Ready=True before touching chart.
3. **Stage one component at a time** — RW frontend, then postgres meta — so each restart is bounded.
4. **In-cluster smoke test before gateway path**: `kubectl run` a psql client pod, port-forward / svc DNS, `sslmode=require` round-trip.
5. **Then wire the gateway VirtualService** (Phase 1) to route external traffic.

## Constraints
- `risingwave-2` is Flux-managed via `iaac-risingwave-2` `main` — PR through that repo.
- Pre/post check: `kubectl get risingwave -n risingwave-2 -o jsonpath='{.items[*].status.conditions}'` Running=True.
- Postgres restart is brief but disruptive to RW (RW uses it as meta store) — expect a 30-60s RW unavailability window. Communicate.

## Links
- Parent: [TCP/SNI ingress umbrella]
- Design doc: [`docs/designs/tcp-sni-ingress-design.md#phase-2`](https://github.com/damoke012/eks_code/blob/main/docs/designs/tcp-sni-ingress-design.md)
- RW-2 repo: https://github.com/variant-inc/iaac-risingwave-2
- Manifest landscape memory: `rw-manifest-landscape-2026-05-28`

## Estimate
M — single-repo manifest change + smoke tests + brief restart window. `risingwave` ns follow-up is a separate ticket once Flux-anchored.

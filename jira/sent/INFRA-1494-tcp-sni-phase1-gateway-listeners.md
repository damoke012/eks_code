---
key: INFRA-1494
status: filed
assignee: Doke
reporter: Doke
created: 2026-05-28
initiative: onprem-networking
labels: [onprem, networking, istio, gateway, sni, phase1]
issuetype: Sub-task
parent: INFRA-1492
---

# Phase 1 — Istio Gateway TCP listeners + SNI passthrough routing

## Context
Extend the existing Istio gateway DaemonSet (HTTP plane today) with TLS-PASSTHROUGH listeners on per-protocol ports (5432 for postgres, 4567 for RW SQL, future 27017/6379/3306). Envoy peeks at SNI in the client TLS hello and routes to the matching backend Service.

## Scope

**In:**
- Add hostPorts to `istio-ingressgateway-values` ConfigMap for protocols actively requested (start: 4567 RW SQL + 5432 postgres).
- New `Gateway` resource `istio-ingress/tcp-passthrough` with PASSTHROUGH servers per port.
- Per-service `VirtualService` with `tls:` match on SNI hostname → route to backend Service.
- external-dns annotations on Gateway resources for A-records to all worker IPs.
- First validation target: `risingwave-2` namespace (Doke-owned, doesn't touch Tim's running workload).

**Out:**
- Backend TLS enablement (Phase 2).
- CIDR allow-list (Phase 3).
- Adding ports for services not yet requested by an app team (defer until demand).

## Definition of done
- [ ] hostPorts 4567 + 5432 added to gateway DaemonSet values; DaemonSet pods restart cleanly across all workers
- [ ] No port conflict on any worker (`ss -lntp` pre-flight clean)
- [ ] `Gateway` + `VirtualService` for `rw2-sql.op-dev.usxpress.io` deployed
- [ ] external-dns creates A-record pointing to all 7 worker IPs
- [ ] `openssl s_client -servername rw2-sql.op-dev.usxpress.io -connect <any-worker-ip>:4567` shows backend's cert (requires Phase 2 first; until then, plaintext psql probe to confirm Envoy is listening and SNI route is wired)
- [ ] RW workload Running=True throughout deploy

## Suggested approach
1. **Pre-flight on a single worker first**: `kubectl debug node/<worker> -- ss -lntp` confirm 4567/5432 are free.
2. **Update ConfigMap + restart gateway DaemonSet rolling**: not all at once. Verify pod-by-pod.
3. **Author Gateway + VirtualService** in `iaac-talos-flux-platform/infrastructure/istio-ingress/` (op-dev branch).
4. **Test SNI routing** with `openssl s_client` before psql — verify the right backend cert comes back per hostname.
5. **External-dns**: ensure `external-dns.alpha.kubernetes.io/target` annotation points at the workers (or use the existing per-Gateway target pattern).

## Constraints
- Depends on Phase 0 (cert-manager wildcard cert) AND Phase 2 for end-to-end test, but the listener itself can ship before Phase 2.
- Hostport additions are additive — no existing service affected.
- Coordinate with Tim BEFORE wiring the `risingwave` namespace (Phase 2 will trigger that).

## Links
- Parent: [TCP/SNI ingress umbrella]
- Design doc: [`docs/designs/tcp-sni-ingress-design.md#phase-1`](https://github.com/damoke012/eks_code/blob/main/docs/designs/tcp-sni-ingress-design.md)
- Istio SNI passthrough docs: https://istio.io/latest/docs/tasks/traffic-management/ingress/ingress-sni-passthrough/

## Estimate
M — additive manifest work + rolling DaemonSet restart + SNI validation. Single repo (iaac-talos-flux-platform).

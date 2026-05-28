---
key: INFRA-1492
status: filed
assignee: Doke
reporter: Doke
created: 2026-05-28
initiative: onprem-networking
labels: [onprem, networking, ingress, tcp, sni, design-doc]
issuetype: Story
parent: none
---

# TCP / SNI ingress pattern for on-prem Talos clusters

## Context
Today on-prem `op-usxpress-dev` only has an HTTP/HTTPS ingress plane (Istio gateway DaemonSet + hostPort, proven 2026-05-19). Non-HTTP TCP services (RisingWave SQL on 4567, postgres on 5432, future MongoDB/Redis-TLS) are exposed via NodePort on worker IPs — no DNS, no TLS, no audit, no CIDR allow-list. This is unsuitable for production.

We need a production-grade TCP ingress pattern that works for any TLS-capable wire protocol (psql, mongo, redis, mysql, mqtt), reuses existing platform components (Istio gateway, cert-manager, external-dns, Cilium, ExternalSecrets/IRSA), and gives app teams the same `<service>.<env>.usxpress.io` UX they get on HTTP.

Design doc with full architecture, security model, per-protocol matrix, and phasing: [`docs/designs/tcp-sni-ingress-design.md`](https://github.com/damoke012/eks_code/blob/main/docs/designs/tcp-sni-ingress-design.md).

## Scope

**In:**
- Extend Istio gateway DaemonSet with TLS-PASSTHROUGH TCP listeners; route by SNI hostname to backend Services.
- Backend pods terminate TLS using cert-manager-issued certs (DNS-01 via Route53 IRSA already trusted).
- Source-CIDR allow-list at gateway via CiliumNetworkPolicy (corp VPN only).
- Per-namespace backend NetworkPolicies + audit log enablement.
- Operational runbook for onboarding new TCP services.
- Apply to `op-usxpress-dev` first; pattern carries to QA/PROD on-prem clusters unchanged.

**Out (explicitly):**
- HTTP/HTTPS plane completion (separate track; Phase 0 of this work unblocks it).
- Kafka ingress (Confluent Cloud — egress only).
- Subzone delegation for `op-dev.usxpress.io` (Steve / network team, separate Jira).
- L7 inspection of TCP payloads (passthrough is opaque by design).
- Replacing the hostPort DaemonSet with MetalLB/BGP (future swap; pattern survives it).

## Definition of done
- [ ] Design doc reviewed and signed off by Steve Duck + Vibin + Dare
- [ ] Phase 0 (cert-manager + wildcard cert) shipped via IaC
- [ ] Phase 1 (TCP/SNI listeners) shipped via IaC, validated with `openssl s_client -servername` to a backend
- [ ] Phase 2 (backend TLS for `risingwave-2` frontend + postgres) shipped, validated psql `sslmode=require` end-to-end from corp VPN
- [ ] Phase 3 (CIDR allow-list) shipped, validated that non-VPN sources are rejected
- [ ] Phase 4 (backend NP + pgaudit + Envoy access log shipping) shipped
- [ ] Phase 5 runbook published in `docs/runbooks/`, includes onboarding checklist + rollback
- [ ] Confirmed RW workload Tim depends on stayed healthy throughout (Running=True, psql round-trip green at each phase)

## Suggested approach
Each phase is an INFRA sub-task underneath this story. Phases are designed to be additive and independently reversible. See the design doc's "Phasing" section for sequencing and the "Risk & rollback" section for failure recovery.

Critical path: Phase 0 → Phase 1 → Phase 2 (for first service). Phases 3-5 can parallelize.

## Constraints
- **Additive over modifying** — must not degrade running `risingwave` workload (Tim coord required for any change touching that namespace).
- **TfApply discipline** in Octopus (`false`=plan, flip `true` to apply, flip back).
- **No AI attribution** in commits / PRs / tickets.
- **Coordinate with Steve / network team** on Phase 0 cert authority choice (LE PROD vs AWS PCA) and subzone delegation.

## Links
- Design doc: [`docs/designs/tcp-sni-ingress-design.md`](https://github.com/damoke012/eks_code/blob/main/docs/designs/tcp-sni-ingress-design.md)
- WIP: [`wip/onprem-networking/STATE.md`](https://github.com/damoke012/eks_code/blob/main/wip/onprem-networking/STATE.md)
- HTTP DNS proof memory: `onprem_hostnetwork_ingress_proof`
- Route53 trust memory: `onprem_route53_wildcard_trust_discovery`

## Estimate
L — six sub-tasks, multiple repos (iaac-talos, iaac-talos-flux-platform, iaac-talos-flux-cluster, iaac-risingwave-2), networking team coord, careful sequencing around Tim's running workload.

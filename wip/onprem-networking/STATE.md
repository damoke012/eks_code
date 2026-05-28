# On-Prem Networking — STATE
*Last updated 2026-05-28 (TCP/SNI prod-grade design + Jira slate filed + Phase 0/1 IaC staged).*

## Where it stands

**HTTP DNS is END-TO-END PROVEN** on op-usxpress-dev (2026-05-19 22:26 UTC). `api.brands.op-dev.usxpress.io` resolves to the 7 worker IPs and returns `HTTP 404` from istio-envoy (expected — no upstream yet).

Architecture decided + working: **Istio gateway DaemonSet + hostPort** + sidecar injection via `istio.io/rev=default` label + external-dns with per-Gateway target annotation. Canonical commit: `8b0fac3` on `iaac-talos-flux-platform` op-dev.

**TCP / SNI ingress prod-grade pattern designed + filed 2026-05-28.** Design doc + 7-ticket Jira slate cover the path from HTTPS plane closure → TCP/SNI listeners → backend TLS → CIDR allow-list → backend NP+audit → runbook. Pattern carries to QA/PROD on-prem clusters unchanged.

## TCP / SNI ingress design (NEW 2026-05-28)

**Design doc:** [`docs/designs/tcp-sni-ingress-design.md`](../../docs/designs/tcp-sni-ingress-design.md)

**Pattern:** Extend the existing Istio gateway DaemonSet with TLS-PASSTHROUGH TCP listeners; route by SNI hostname to backend Services; backends terminate TLS using cert-manager-issued certs; source-CIDR allow-list at gateway via CiliumNetworkPolicy. One control plane (Istio), one cert chain (cert-manager + Route53), one DNS plane (external-dns).

**Why this is the prod pattern (vs NodePort):** native TLS in transit, hostname-based fan-out, audit at gateway + backend, CIDR allow-list at the cluster edge, works for any TLS-capable wire protocol (psql, mongo, redis-TLS, mysql, mqtt). Reuses existing platform components.

## Filed Jira slate (INFRA project)

| Key | Type | Summary |
|---|---|---|
| [INFRA-1492](https://usxpress.atlassian.net/browse/INFRA-1492) | Story (umbrella) | TCP / SNI ingress pattern for on-prem Talos clusters |
| [INFRA-1493](https://usxpress.atlassian.net/browse/INFRA-1493) | Sub-task | Phase 0 — cert-manager + Route53 IRSA + wildcard cert |
| [INFRA-1494](https://usxpress.atlassian.net/browse/INFRA-1494) | Sub-task | Phase 1 — Istio Gateway TCP listeners + SNI passthrough |
| [INFRA-1495](https://usxpress.atlassian.net/browse/INFRA-1495) | Sub-task | Phase 2 — Backend TLS enablement (risingwave-2 first, then risingwave) |
| [INFRA-1496](https://usxpress.atlassian.net/browse/INFRA-1496) | Sub-task | Phase 3 — Source-CIDR allow-list via CiliumNetworkPolicy |
| [INFRA-1497](https://usxpress.atlassian.net/browse/INFRA-1497) | Sub-task | Phase 4 — Backend NetworkPolicy + audit logging |
| [INFRA-1498](https://usxpress.atlassian.net/browse/INFRA-1498) | Sub-task | Phase 5 — Operational runbook + onboarding checklist |

Markdown drafts at [`jira/sent/INFRA-149*-tcp-sni-*.md`](../../jira/sent/). All assigned to Doke.

## IaC drafts staged (codespace, ready for WSL pickup)

| Phase | Path | Status |
|---|---|---|
| 0 | [`iaac-drafts/onprem-cert-manager/`](../../iaac-drafts/onprem-cert-manager/) | Drafted: IAM role TF + cert-manager HelmRelease + ClusterIssuers (LE staging + prod) + wildcard cert + RUNBOOK |
| 1 | [`iaac-drafts/onprem-tcp-sni-ingress/`](../../iaac-drafts/onprem-tcp-sni-ingress/) | Drafted: values delta + Gateway TLS-PT + 2x VirtualService + RUNBOOK |
| 2-5 | (not yet authored) | Track via INFRA-1495..1498 |

Apply via WSL once user approves (codespace can't reach cluster). Pre-flight + smoke + rollback are in each phase's RUNBOOK.

## Key links

- Design doc: [`docs/designs/tcp-sni-ingress-design.md`](../../docs/designs/tcp-sni-ingress-design.md)
- Steve message draft (NOT yet sent — should be updated to consolidate HTTPS + TCP SNI + subzone as one ask): [`steve_duck_networking_message_draft_may13.md`](steve_duck_networking_message_draft_may13.md)
- hostNetwork/hostPort ingress proof (May 13): memory `onprem_hostnetwork_ingress_proof`
- iaac-route53-zone trust verified (May 18): wildcard accepts `extd-usxpress-io-*` AND `cert-manager-*` from USXpress AWS Org — no patch needed.

## Decisions made

- **Gateway pattern:** Istio gateway DaemonSet + hostPort.
- **L2 / BGP fallback:** Cilium L2/ARP LoadBalancer Services don't reach VPN clients. NodePort + worker IPs is the DEV-only stopgap; SNI passthrough (this design) is the prod path.
- **IAM role naming:** `extd-usxpress-io-op-usxpress-dev` (external-dns, shipped); `cert-manager-op-usxpress-dev` (cert-manager, Phase 0) — both match wildcard trust on iaac-route53-zone.
- **TLS termination:** backend pod, NOT the gateway (passthrough means clients negotiate native protocol TLS with the server).
- **Cert authority:** LE PROD as default; AWS PCA TBD with Steve (design doc §"Open questions").

## Open items

| Item | Owner | Notes |
|------|-------|-------|
| **HTTPS** — cert-manager + Route53 wildcard | Doke (INFRA-1493) | Unblocks both HTTPS plane AND TCP/SNI Phase 1. IaC drafted today. |
| **TCP gateway** — Istio TCP/SNI routing | Doke (INFRA-1494) | IaC drafted today. |
| **Send the Steve message** | Doke | Consolidate ask: HTTPS + TCP SNI + subzone as one conversation. Existing draft needs an update. |
| **Subzone delegation** — `op-dev.usxpress.io` formal delegation | Steve / Doke | Route53 trust works without it; formal delegation tidies ownership. |

## Risk / watch-outs

- **Dare's track, NOT Idris's.** Networking team coordination is Doke/Dare. Don't loop Idris in.
- Networking team turnaround can be slow — bias toward additive, opt-in changes (this design IS additive — no existing service is modified).
- **Don't degrade Tim's RW workload.** Any networking change on op-usxpress-dev must NOT affect the running RW; additive over modifying; coord with Tim before invasive changes.
- **TfApply discipline** for Phase 0 IAM role: `false` → plan, flip `true` to apply, flip back to `false`.
- **No AI attribution** in any commits / PRs / issues.

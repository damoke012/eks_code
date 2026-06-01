# On-Prem Networking — STATE
*Last updated 2026-06-01 (Mon) — **Phase 1 (INFRA-1494) DONE end-to-end.***

**Phase 1 closed 2026-06-01.** TCP/SNI listeners 4567 + 5432 live on `istio-ingressgateway`; `rw2-sql.op-dev.usxpress.io` DNS resolves to all 7 worker IPs; `openssl s_client` reaches the gateway and proxies to `risingwave-frontend.risingwave-2.svc` (backend RST as expected pre-Phase-2). Full closure trail: [`phase1-closure-jun01.md`](phase1-closure-jun01.md).

**Networking + CySec call review** (2026-05-29): [`networking-call-review-may29.md`](networking-call-review-may29.md). 7 follow-up tickets filed (INFRA-1502..1508). Pre-call prep: [`steve-meeting-prep-may29.md`](steve-meeting-prep-may29.md).

## Where it stands

**HTTP DNS proven** 2026-05-19. **Phase 0 of TCP/SNI ingress (cert-manager + IRSA + wildcard cert) SHIPPED 2026-05-28.** **Track A HTTPS plane SHIPPED same day** — `shared-http` Gateway with multi-SNI server blocks (depth-1 wildcard + per-team wildcards). Real TLS 1.3 + HTTP/2 proven from corp VPN against `api.brands.op-dev.usxpress.io`. **Gateway DaemonSet 7/7 Ready** (the 8-day regression got fixed via istiod right-size in the same session). HR + Kustomization both Ready=True.

Architecture: **Istio gateway DaemonSet + hostPort** + sidecar injection via `istio.io/rev=default` + external-dns with per-Gateway target annotation. **Single shared Gateway** (`istio-ingress/shared-http`) with multiple TLS server blocks SNI-routed by Envoy. Canonical commit on op-dev: **`fb03b87`** (Track A complete).

## ✅ Track A closed — HTTPS plane operational

| Component | State |
|---|---|
| `Gateway istio-ingress/shared-http` | HTTP :80 + HTTPS :443 (two server blocks for two certs) |
| `Certificate wildcard-op-dev` | `*.op-dev.usxpress.io`, depth-1 wildcard, valid through 2026-08-26 |
| `Certificate brands-op-dev` | `*.brands.op-dev.usxpress.io`, depth-2 per-team wildcard, valid through 2026-08-26 |
| TLS handshake from corp VPN | TLS 1.3 + HTTP/2 to `api.brands.op-dev.usxpress.io` SAN matched |
| Pattern scalability | Each future on-prem team domain = 1 new Certificate + 1 server block on shared-http. Depth-1 hostnames need no per-team work. |

**PRs:** iaac-talos-flux-platform [#11](https://github.com/variant-inc/iaac-talos-flux-platform/pull/11) (shared-http Gateway), [#12](https://github.com/variant-inc/iaac-talos-flux-platform/pull/12) (brands cert + server block).

## ✅ Worker-4 / istio-ingress regression — RESOLVED 2026-05-28 same session

Same day as Phase 0 + Track A. [PR #10](https://github.com/variant-inc/iaac-talos-flux-platform/pull/10) — `pilot.resources.requests.memory: 2Gi → 1Gi` in `istiod-values` ConfigMap. Worker-4 memory 3310Mi → 1390Mi, gateway DS 6/7 → 7/7, HR Ready=True (was Failed for 8 days). istiod restart was clean — no cert drift.

## ✅ Worker-4 / istio-ingress regression — RESOLVED 2026-05-28 same session

| Before | After |
|---|---|
| 8-day-old HR install-failure | HR Ready=True (Helm upgrade succeeded at 21:51:49 UTC) |
| Gateway DS 6/7 (one pod Pending on worker-4) | **7/7 Running, Ready, Available** |
| Worker-4 memory 3310Mi / 97% allocated | **1390Mi / 40%** (~1.9Gi freed) |
| Kustomization `istio-ingress` False | Ready=True |

**Fix:** [PR #10](https://github.com/variant-inc/iaac-talos-flux-platform/pull/10) on op-dev — `pilot.resources.requests.memory: 2Gi → 1Gi` in `istiod-values` ConfigMap. Single istiod restart, no cert drift, mesh PKI unchanged, RW workloads Running=True throughout.

See [memory `istiod_memory_rightsize_may28`](../../wip/onprem-networking/STATE.md) for the gotchas captured (valuesFrom-ConfigMap reconcile requires `flux reconcile helmrelease`, sticky HR install-failure needs `--force`).

## ✅ Phase 0 closed (INFRA-1493) — 2026-05-28

| Component | State |
|---|---|
| IAM role `cert-manager-op-usxpress-dev` | Created in AWS 700736442855, chains into `iaac-route53-zone` |
| cert-manager v1.19.1 | Unchanged release; IRSA SA annotation patched additively |
| LE staging + prod ClusterIssuers | Both Ready=True |
| Wildcard `*.op-dev.usxpress.io` cert | Ready=True from LE PROD intermediate YR1; valid through 2026-08-26; Secret `wildcard-op-dev-tls` in `istio-ingress` ns |
| Mesh PKI (istio-csr, istio-ca, istiod) | Untouched, pod ages still 8d+ |

**PRs:** iaac-talos [#31](https://github.com/variant-inc/iaac-talos/pull/31) + [#32](https://github.com/variant-inc/iaac-talos/pull/32) (tag-parens fix), iaac-talos-flux-platform [#9](https://github.com/variant-inc/iaac-talos-flux-platform/pull/9); iaac-talos-flux-cluster [#6](https://github.com/variant-inc/iaac-talos-flux-cluster/pull/6) closed as redundant (Kustomizations already existed).

**Octopus:** iaac-talos release `0.1.0-feature-op-usxpress-dev.1.150` applied 2 resources (role + policy) at 20:15:19 UTC. TfApply flipped back to false.

**Smoke validation:** staging smoke 2m27s, wildcard PROD 3m20s — full IRSA chain (cert-manager pod → cert-manager IAM role → iaac-route53-zone role → Route53 _acme TXT) verified end-to-end.

## TCP / SNI ingress design (2026-05-28)

**Design doc:** [`docs/designs/tcp-sni-ingress-design.md`](../../docs/designs/tcp-sni-ingress-design.md)

**Pattern:** Extend the existing Istio gateway DaemonSet with TLS-PASSTHROUGH TCP listeners; route by SNI hostname to backend Services; backends terminate TLS using cert-manager-issued certs; source-CIDR allow-list at gateway via CiliumNetworkPolicy. One control plane (Istio), one cert chain (cert-manager + Route53), one DNS plane (external-dns).

**Why this is the prod pattern (vs NodePort):** native TLS in transit, hostname-based fan-out, audit at gateway + backend, CIDR allow-list at the cluster edge, works for any TLS-capable wire protocol (psql, mongo, redis-TLS, mysql, mqtt). Reuses existing platform components.

## TCP / SNI ingress design (NEW 2026-05-28)

**Design doc:** [`docs/designs/tcp-sni-ingress-design.md`](../../docs/designs/tcp-sni-ingress-design.md)

**Pattern:** Extend the existing Istio gateway DaemonSet with TLS-PASSTHROUGH TCP listeners; route by SNI hostname to backend Services; backends terminate TLS using cert-manager-issued certs; source-CIDR allow-list at gateway via CiliumNetworkPolicy. One control plane (Istio), one cert chain (cert-manager + Route53), one DNS plane (external-dns).

**Why this is the prod pattern (vs NodePort):** native TLS in transit, hostname-based fan-out, audit at gateway + backend, CIDR allow-list at the cluster edge, works for any TLS-capable wire protocol (psql, mongo, redis-TLS, mysql, mqtt). Reuses existing platform components.

## Filed Jira slate (INFRA project)

All under Epic [INFRA-1499](https://usxpress.atlassian.net/browse/INFRA-1499) "On-Prem Production-Grade Ingress (HTTPS + TCP/SNI)" which rolls up to Initiative [INFRA-472](https://usxpress.atlassian.net/browse/INFRA-472).

| Key | Type | Status | Summary |
|---|---|---|---|
| [INFRA-1492](https://usxpress.atlassian.net/browse/INFRA-1492) | Story (umbrella) | In Progress | TCP / SNI ingress pattern for on-prem Talos clusters |
| [INFRA-1493](https://usxpress.atlassian.net/browse/INFRA-1493) | Sub-task | ✅ **Done** | Phase 0 — cert-manager + Route53 IRSA + wildcard cert |
| [INFRA-1494](https://usxpress.atlassian.net/browse/INFRA-1494) | Sub-task | To Do | Phase 1 — Istio Gateway TCP listeners + SNI passthrough |
| [INFRA-1495](https://usxpress.atlassian.net/browse/INFRA-1495) | Sub-task | To Do | Phase 2 — Backend TLS enablement (risingwave-2 first, then risingwave) |
| [INFRA-1496](https://usxpress.atlassian.net/browse/INFRA-1496) | Sub-task | To Do | Phase 3 — Source-CIDR allow-list via CiliumNetworkPolicy |
| [INFRA-1497](https://usxpress.atlassian.net/browse/INFRA-1497) | Sub-task | To Do | Phase 4 — Backend NetworkPolicy + audit logging |
| [INFRA-1498](https://usxpress.atlassian.net/browse/INFRA-1498) | Sub-task | To Do | Phase 5 — Operational runbook + onboarding checklist |

Markdown drafts at [`jira/sent/INFRA-149*-tcp-sni-*.md`](../../jira/sent/). All assigned to Doke.

## Open items + next-track decisions

| Item | Owner | Notes |
|---|---|---|
| ~~**Worker-4 / istio-ingress regression**~~ | ~~Doke~~ | ✅ RESOLVED 2026-05-28 via PR #10 istiod right-size. |
| ~~**Track A — HTTPS plane completion**~~ | ~~Doke~~ | ✅ SHIPPED 2026-05-28 via PRs #11 + #12. Pattern in [memory `onprem_per_team_cert_pattern_may28`](../../wip/onprem-networking/STATE.md). |
| **Phase 1 — TCP/SNI listeners (INFRA-1494)** | Doke | NEXT. IaC drafts at [`iaac-drafts/onprem-tcp-sni-ingress/`](../../iaac-drafts/onprem-tcp-sni-ingress/). All prerequisites (cert-manager + healthy gateway HR + cluster baseline) are now true. |
| **App-team VS migration** | App teams | New ask for app teams: point VirtualServices at `gateways: [istio-ingress/shared-http]` to get HTTPS. Currently zero VirtualServices exist on this cluster, so this is a forward-looking onboarding ask, not a migration. |
| **Worker memory expansion 4Gi → 8Gi** | Doke (weekend) | No longer urgent. Capacity headroom move. |
| **Idris's PR #7 (iaac-talos-flux-cluster)** | Idris | Request-changes posted; waiting on his fixes + Tim coord. |
| **Send the Steve message** | Doke | Phase 0 + Track A proved no network team coord needed for cert chain. Subzone delegation is the remaining Steve item. Draft is stale; rewrite or skip. |

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

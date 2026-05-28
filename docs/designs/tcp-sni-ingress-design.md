---
title: TCP / SNI Ingress for On-Prem Talos — Production Pattern
status: Draft
author: Doke
created: 2026-05-28
reviewers: Steve Duck (networking), Vibin Vargheese (platform), Dare (on-prem)
related_jira: INFRA-1492 (umbrella; see jira/sent/)
supersedes: NodePort access in `risingwave-2` and `risingwave` namespaces (interim)
---

# TCP / SNI Ingress for On-Prem Talos — Production Pattern

## TL;DR

Extend the existing Istio Gateway DaemonSet with TCP listeners in **TLS PASSTHROUGH** mode, route by **SNI hostname** to backend Services, terminate TLS on the **backend pod** (cert-manager-issued cert), and lock down with **CiliumNetworkPolicy** for source-CIDR allow-listing.

One control plane (Istio), one cert chain (cert-manager + Route53 DNS-01), one DNS plane (external-dns), one audit log (Envoy access logs + backend audit). Same pattern works for **any TLS-capable TCP protocol** — psql/RisingWave SQL, MongoDB-TLS, Redis-TLS, MySQL-TLS, MQTT-TLS, gRPC over HTTP/2 — across DEV/QA/PROD clusters.

This is the production target. NodePort stays as a DEV-only stop-gap until Phase 1 ships.

## Background

| | State |
|---|---|
| HTTP / HTTPS plane | HTTP DNS proven end-to-end 2026-05-19. HTTPS pending cert-manager. |
| Non-HTTP TCP plane | NodePort on worker IPs (e.g. `10.10.82.26:32567` for RW frontend). No DNS, no TLS, no audit, port collisions. |
| Cluster | `op-usxpress-dev` — 3 CP + 7 workers, Talos v1.32. Both `risingwave` and `risingwave-2` namespaces live here. |
| Network reach | Worker IPs are VPN-routable from corp. Cilium L2/ARP LoadBalancer doesn't reach VPN clients (no BGP). hostPort DaemonSet pattern proven viable as the workaround. |
| Cert authority for `op-dev.usxpress.io` | IAM trust on `iaac-route53-zone` already accepts `cert-manager-*` and `extd-usxpress-io-*` IRSA roles from USXpress AWS Org. No network-team turnaround required. |

## Goals

1. Single, repeatable pattern for **all non-HTTP TCP ingress** across on-prem clusters (DEV today, QA/PROD when promoted).
2. **Encryption in transit** by default — no plaintext on the wire.
3. **Source-CIDR allow-listing** at the cluster edge (corp VPN ranges only).
4. **Hostname-based fan-out** for TLS-capable protocols, so app teams get `<service>.<env>.usxpress.io` URLs (same UX as HTTP).
5. **Reuse** existing platform components (Istio, cert-manager, external-dns, Cilium, AWS SM via ExternalSecrets, IRSA).
6. **Additive deployment** — must not degrade the running `risingwave` workload Tim depends on.

## Non-goals

- Replacing the HTTP/HTTPS plane.
- Kafka ingress (Kafka is Confluent Cloud — egress only).
- Cloud-cluster ingress (cloud EKS uses ALB; pattern is intentionally on-prem-specific).
- L7 inspection of TCP payloads — passthrough is opaque by design.
- Protocols that cannot speak TLS client-side (covered separately in §"Fallback for non-TLS protocols").

## Architecture

```
                                  corp VPN client
                                       │
                                       │  TLS to <service>.op-dev.usxpress.io:<port>
                                       │  (psql --sslmode=require, mongosh --tls, redis-cli --tls)
                                       ▼
   ┌───────────────────────────────────────────────────────────────────┐
   │                       Istio Gateway DaemonSet                     │
   │              (existing, today binds 80/443 hostPort)              │
   │   ┌─────────────────┐   ┌─────────────────┐   ┌────────────────┐  │
   │   │ :80  HTTP       │   │ :443 HTTPS      │   │ :5432 TLS-PT   │  │
   │   │  (existing)     │   │  (Phase 0)      │   │  SNI route     │  │
   │   └─────────────────┘   └─────────────────┘   └────────────────┘  │
   │   ┌────────────────┐   ┌─────────────────┐                        │
   │   │ :4567 TLS-PT   │   │ :6379 TLS-PT   │   ... per protocol     │
   │   │  SNI route     │   │  SNI route     │                         │
   │   └────────────────┘   └─────────────────┘                        │
   └───────────────────────────────────────────────────────────────────┘
                                       │  (SNI = rw2-sql.op-dev.usxpress.io)
                                       │  raw bytes after SNI peek
                                       ▼
   ┌───────────────────────────────────────────────────────────────────┐
   │                        Backend Service (TLS)                     │
   │   risingwave-frontend.risingwave-2.svc:4567 (TLS on, cert from   │
   │   cert-manager Certificate `risingwave-2-frontend-tls`)          │
   └───────────────────────────────────────────────────────────────────┘
                                       │  app auth (psql SCRAM/LDAP)
                                       ▼
                                  RisingWave
```

**Key choices:**

| Choice | Rationale |
|---|---|
| **TLS PASSTHROUGH (not termination)** at the gateway | psql/mongo/redis do their own TLS handshake. Passthrough lets the gateway peek at SNI in the client hello (before cipher exchange) to pick a backend, then proxies bytes. Avoids re-encrypting and replaying protocol negotiation. |
| **SNI routing, not port-per-service** | One port per protocol family — many backends share that port, fanned out by hostname. Same UX as HTTP DNS. |
| **Backend pod terminates TLS** | Cert lives on the backend; rotation via cert-manager; cipher policy owned by the app. No double-TLS hop. |
| **DaemonSet on every worker** | No L2/BGP dependency. DNS A-record round-robins to all 7 worker IPs. Proven by the HTTP DNS work. |
| **No mTLS at the gateway by default** | Backend handles auth (SCRAM/LDAP/cert). Optional mTLS at the gateway is a per-service opt-in (see §"mTLS opt-in"). |
| **CiliumNetworkPolicy at the gateway** | L3/L4 source-CIDR allow-list applied to gateway pods. Defense in depth — backends also have NetworkPolicy. |

## Security model

### Layered controls

1. **Network reach** — corp VPN CIDR allow-list via `CiliumNetworkPolicy` on the gateway DaemonSet pods. Anything else gets a TCP reset before the TLS handshake.
2. **Server identity** — cert-manager-issued public cert (Let's Encrypt or AWS PCA, see §"Open question: LE vs PCA") on the backend pod. Clients verify hostname.
3. **Application auth** — per-protocol, unchanged: psql SCRAM-SHA-256 or LDAP, MongoDB SCRAM, redis ACL, etc. Creds via AWS SM → ExternalSecrets.
4. **Application authz** — per-protocol: postgres `pg_hba.conf`, RisingWave roles, mongo roles. App team owns.
5. **mTLS opt-in** — sensitive backends (e.g., write-path psql) can require client cert at the gateway via Istio `PeerAuthentication` STRICT on a per-port AuthorizationPolicy. Client certs issued from a private CA (operator/SRE only).
6. **Encryption at rest** — backend pod TLS keys held as k8s Secrets (cert-manager output) — encrypted via EncryptionConfiguration on Talos (out of scope for this design, tracked separately).
7. **Audit** — Envoy access log per TCP session at the gateway (source IP, SNI, duration, bytes); per-protocol audit at the backend (pgaudit, mongo audit log).
8. **Rate / connection limits** — Envoy `connection_limit` filter per source IP. Backend-side `max_connections` retained.

### Threat model — what this stops

| Threat | Control |
|---|---|
| Random internet → cluster TCP probe | Corp VPN reach + CiliumNetworkPolicy CIDR allow-list |
| Malicious VPN client trying to hit non-allow-listed port | Gateway only binds the protocol ports we declare |
| Plain-text credential capture on VPN | TLS PASSTHROUGH end-to-end |
| Compromised app pod → lateral pivot to other backend | NetworkPolicy on backend pods (per-namespace, namespace-selectors only) |
| Cert mis-issuance / wrong hostname | DNS-01 challenge ties cert to DNS zone control; Route53 trust scoped to `extd-usxpress-io-*` / `cert-manager-*` IRSA roles |
| Stolen IRSA token for cert-manager | OIDC trust scoped to one ServiceAccount + cluster JWT issuer; rotation tied to cluster lifecycle |
| Replay / session hijack | TLS forward-secret cipher suites (TLS 1.3 preferred) |

### Threat model — what this does NOT stop

- App-layer SQL injection / abuse — that's the app's problem (RW roles, pgaudit, RW resource limits).
- Compromised IRSA cert-manager role issuing arbitrary certs in `op-dev.usxpress.io` — mitigated by scoping the trust to one SA name and one role-name pattern.
- DoS at the L4 layer beyond Envoy's per-IP connection limit — would need an upstream firewall / corp VPN concentrator rate limit.

## Per-protocol applicability

| Protocol | TLS-capable | SNI sent by client? | Pattern | Port |
|---|---|---|---|---|
| **PostgreSQL / RisingWave SQL** | Yes (TLS upgrade) | Yes (libpq ≥14, default) | SNI passthrough | 5432 (pg), 4567 (RW) |
| MongoDB | Yes | Yes (drivers ≥3.6) | SNI passthrough | 27017 |
| Redis | Yes (`tls-port`) | Yes (`redis-cli --tls --sni`) | SNI passthrough | 6379 |
| MySQL | Yes (`require_secure_transport`) | Yes (MySQL ≥8) | SNI passthrough | 3306 |
| MQTT | Yes (`mqtts`) | Yes | SNI passthrough | 8883 |
| gRPC | Yes (HTTP/2 over TLS) | Yes | Already covered by HTTPS plane | 443 |
| Kafka (broker → broker) | Yes (SASL_SSL) | Partially — broker advertises own addr | Out of scope (Confluent Cloud) | n/a |
| SMTP / IMAP / FTP / SFTP | Varies | Varies | Per-case (port + SNI if upgraded TLS); document on adoption | per service |

## Fallback for non-TLS protocols

For TCP protocols that cannot speak TLS client-side (rare in our stack — most modern data-plane software supports TLS):

- **Allocate a stable port** on the gateway DaemonSet (e.g., `5433` for plaintext psql).
- **TCP route** (no TLS, no SNI) to a single backend Service.
- **Hostname-based routing is NOT possible** — port acts as the discriminator. One backend per port.
- **CIDR allow-list still applies** at the gateway.
- **Encryption at L4** via an outer TLS tunnel (stunnel, spiped) on the client side, OR VPN-level encryption only.

This is intentionally awkward — it forces app teams toward TLS-capable backend builds. Document as a last-resort pattern.

## Phasing

Each phase is independently shippable, reversible, and additive.

### Phase 0 — cert-manager + Route53 IRSA + wildcard cert  (PREREQ for HTTPS plane too)
1. IAM role `cert-manager-op-usxpress-dev` (matches `iaac-route53-zone` trust pattern), zone-scoped to `op-dev.usxpress.io`.
2. cert-manager HelmRelease in `cert-manager` namespace with IRSA ServiceAccount annotation.
3. `ClusterIssuer` for Let's Encrypt PROD via DNS-01 against the IAM role.
4. Wildcard `Certificate` `*.op-dev.usxpress.io` in `istio-ingress` namespace (gateway TLS use) AND per-namespace certs for backends.

**Acceptance:** `kubectl describe certificate -n istio-ingress wildcard-op-dev` shows `Ready=True`, cert validates against public CA, no cluster service degradation.

### Phase 1 — Gateway TCP listeners + SNI routing  (NEW)
1. Extend `istio-ingressgateway-values` ConfigMap: add hostPorts for `5432`, `4567`, `27017`, `6379`, `3306` (start narrow — only enable per actual demand).
2. New `Gateway` resource `istio-ingress/tcp-passthrough` with TLS-mode `PASSTHROUGH` servers per port.
3. Per-service `VirtualService` with `tls:` match on SNI hostname → route to backend Service.
4. external-dns annotations on Gateway resources for A-records.

**Acceptance:** `openssl s_client -servername <host>:<port> -connect <worker-ip>:<port>` returns the backend's cert; psql connect succeeds end-to-end.

### Phase 2 — Backend TLS enablement (per-service)
1. **RisingWave-2 frontend**: enable `tls.enabled` in `iaac-risingwave-2` HelmRelease values; cert from cert-manager `Certificate` in `risingwave-2` ns.
2. **Postgres-postgresql (RW meta backend)**: chart `tls.enabled: true` + `existingSecret` referencing cert-manager output.
3. Per-service ExternalSecret if any.
4. **Coordinate with Tim** before touching anything in `risingwave` namespace — Tim is actively running queries. See INFRA-1487 / [[feedback_protect_rw_onprem_workload]].

**Acceptance:** pods restart cleanly, RW Running=True post-change, psql `sslmode=require` succeeds from in-cluster client.

### Phase 3 — Source-CIDR allow-list (CiliumNetworkPolicy)
1. `CiliumNetworkPolicy` in `istio-ingress` ns selecting the gateway DaemonSet pods.
2. Allow ingress from the corp VPN CIDR range(s) on TCP ports (`5432`, `4567`, etc).
3. Deny default.

**Acceptance:** TCP connect from corp VPN succeeds, TCP connect from any other source RST/drops.

### Phase 4 — Backend NetworkPolicy + audit log enablement
1. Backend ns NetworkPolicy: ingress only from gateway DaemonSet pods (namespace + pod selector).
2. Enable pgaudit on postgres-postgresql (chart values).
3. Envoy access log to stdout — picked up by existing log shipping.

**Acceptance:** unauthorized cross-namespace pod cannot reach backend; access logs flow to centralized store.

### Phase 5 — Operational runbook + on-call docs
1. Onboarding runbook: how to expose a new TCP service via this pattern (per-service checklist).
2. Rollback runbook: how to disable a TLS-PT port without affecting others.
3. Troubleshooting: openssl s_client recipes, common SNI mismatches, cert-rotation incidents.
4. SLOs: gateway availability, p99 TCP setup latency.

## Sequencing & dependencies

```
Phase 0 (cert-manager + wildcard) ─┬─► Phase 1 (TCP listeners + SNI)
                                   └─► HTTPS plane (parallel track)

Phase 1 ─► Phase 2 (per-service backend TLS) ─► Phase 4 (NP + audit)

Phase 3 (CIDR allow-list) — can ship anytime after Phase 1
Phase 5 (runbook) — alongside Phase 4
```

**Critical path:** Phase 0 → 1 → 2 (for first service). Other phases parallelize.

## Risk & rollback

| Risk | Mitigation | Rollback |
|---|---|---|
| Phase 1 adds hostPort that conflicts with another worker process | Pre-flight `netstat`/`ss` on workers; only enable ports we control | Remove hostPort from values; DaemonSet restart |
| Phase 2 RW frontend TLS misconfigured, psql connections break | Stage in `risingwave-2` (Doke-owned) before touching `risingwave` (Tim's). Test with port-forward to TLS-enabled frontend before opening gateway. | HelmRelease values rollback; pod restart |
| cert-manager IRSA mis-issued | Trust scoped to specific SA + role name; nothing else can assume | Detach SA annotation; role deactivates immediately |
| Source CIDR allow-list locks out legitimate user | Stage policy in `--dry-run` mode; review Envoy access logs for blocked sources before enforcing | Delete CNP; default-allow restored |
| Cilium NP doesn't actually filter (we're on hostPort, not the Cilium-managed eth path) | Verify with a probe from outside the corp CIDR before declaring done; consider iptables-on-worker fallback | Doc the gap, escalate to network team for firewall layer |

## Operational requirements

- **cert-manager monitoring**: alerts on cert expiry < 14 days, issuance failures.
- **Gateway DaemonSet monitoring**: pod ready count = worker count; restart count; Envoy listener status.
- **Per-service smoke tests**: cronjob that opens a TLS connection to each exposed backend daily.
- **Backup of cert-manager state**: Order resources in the cert-manager ns (irrecoverable if lost; cert-manager can re-issue but disruptive).
- **Quarterly review** of CIDR allow-list (corp VPN ranges change).
- **Per-service exposure approval flow**: app team requests via INFRA Jira ticket → platform reviews → adds Gateway/VirtualService manifest. Prevents random ports being opened.

## Open questions

1. **Let's Encrypt PROD vs AWS Private CA** — LE is simpler/free; AWS PCA gives us a trusted-internal cert chain with no rate limits and no external dependency. Steve to weigh in.
2. **Subzone delegation for `op-dev.usxpress.io`** — current state is parent-zone-managed. Steve's call whether to formally delegate.
3. **mTLS at the gateway for write-path services** — defer, file as separate INFRA story once first read-only service is live.
4. **Per-cluster vs single-zone certs** — when QA/PROD on-prem clusters land, do we use `op-qa.usxpress.io` / `op-prod.usxpress.io` subzones, or namespace-per-env in the same zone? Recommendation: subzone per cluster (cleaner blast radius); confirm with Steve.
5. **BGP eventually** — if/when network team enables BGP, MetalLB can replace the hostPort DaemonSet for cleaner L4. Pattern above survives the swap — only the data path changes; SNI/Gateway/cert layers are unaffected.

## Out of scope (tracked elsewhere)

- Subzone delegation (Steve track, separate Jira).
- HTTPS plane completion (Phase 0 unblocks it; separate story).
- Kafka egress hardening (Confluent Cloud network track).
- Pre-existing NodePort cleanup (handled per-service as TCP-SNI takes over).

## References

- [`wip/onprem-networking/STATE.md`](../../wip/onprem-networking/STATE.md)
- [`wip/onprem-networking/steve_duck_networking_message_draft_may13.md`](../../wip/onprem-networking/steve_duck_networking_message_draft_may13.md)
- [Istio docs: Configure traffic with SNI Passthrough](https://istio.io/latest/docs/tasks/traffic-management/ingress/ingress-sni-passthrough/)
- [cert-manager docs: DNS-01 challenge with Route53](https://cert-manager.io/docs/configuration/acme/dns01/route53/)
- Memory: [[onprem_hostnetwork_ingress_proof]] — hostNetwork/hostPort viability proven
- Memory: [[onprem_route53_wildcard_trust_discovery]] — IAM trust pre-arranged
- Memory: [[feedback_protect_rw_onprem_workload]] — additive-over-modifying; coord with Tim

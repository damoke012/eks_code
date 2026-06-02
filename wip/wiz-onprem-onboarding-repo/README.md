# Wiz CNAPP Onboarding — On-Prem Talos Clusters

> Onboarding plan, alert-pillar design, and coordination tracker for [Wiz](https://www.wiz.io/) eBPF runtime security on the USXpress on-prem Talos clusters. First target: `op-usxpress-dev`. Pattern carries to QA + PROD.

---

## Background

- USXpress is migrating from **Orca** (cloud-only) to **Wiz** for security observability that covers **both AWS and on-prem**.
- Decided at the **2026-05-29 networking + CySec sync** (Steve Duck, Brendan Buschel, Steve Vives, Doke).
- Wiz model: **eBPF sensors deployed as a DaemonSet on every worker** for kernel-level visibility. Onboarding focus is alerting + posture + reporting, not where to install the sensor.
- Steve Vives is the build-out lead (~2 weeks into Wiz install on the AWS side at time of writing).
- This onboarding does **not** block any current on-prem networking phase. Phases 0–3 (cert-manager, Track A HTTPS, TCP/SNI, backend TLS, CNP source-CIDR) are already shipped on `op-usxpress-dev` (June 2026).

## Architecture

**Sensor:** Wiz eBPF DaemonSet on every Talos worker node (10 nodes on `op-usxpress-dev`: 3 control plane + 7 workers).

**Egress:** Wiz sensor needs outbound to `wiz.io` endpoints (TBD — confirm with Steve Vives). On-prem cluster worker subnet `10.10.82.0/24` is the source.

**What Wiz adds vs what Prometheus already covers:**

| Concern | Owner | Notes |
|---|---|---|
| HTTP 4xx/5xx, latency, ingress-gateway-down, node-not-ready, pod CrashLoop | **Prometheus** | Shipped in [`PrometheusRule platform-health`](https://github.com/variant-inc/iaac-talos-flux-platform/pull/24) (INFRA-1503) |
| Cert expiry + cert-manager rotation health | **Prometheus** | Same PrometheusRule, certificates group |
| Flux reconcile failures (Kustomization / HelmRelease / GitRepository) | **Prometheus** | Same PrometheusRule, flux group |
| CVE / image vulnerability scanning | **Wiz** | Runtime detection on running images |
| Container drift / runtime behavior anomalies | **Wiz** | eBPF strength |
| Container escape / privilege escalation | **Wiz** | eBPF strength |
| Over-permissive RBAC, secret exposure, posture drift | **Wiz** | Identity + secrets posture |
| External exposure audit (which Services are reachable from outside?) | **Wiz** | Surface-level visibility |
| Threat-intel matched source IPs / suspicious request patterns | **Wiz** | L7 threat signals |

**Rule of thumb:** Prometheus answers "is it up + healthy + on-time?" Wiz answers "is it secure + behaving normally + uncompromised?"

---

## The Four Pillars

Alerting + reporting focus areas. Each pillar lists concrete alert categories proposed; the alerts are sanity-checks for Steve Vives — he confirms what Wiz can actually deliver and we trim or rescope accordingly.

### 1. RisingWave data plane

Why a pillar: customer / Kafka stream data lives here, plus the postgres meta stores. This is the highest-value tenant on the cluster today.

Proposed alert categories:
- CVE / image vulnerabilities in `risingwave`, `postgres`, `ghostunnel`, `risingwave-operator` images
- Anomalous outbound connections from RW pods (unexpected destinations / regions)
- Unauthorized ServiceAccounts reading the `rw-root-credentials` Secret
- Container drift from declared state (StatefulSet pod spec vs actual)
- Suspected sensitive data in logs (PII patterns, credentials in stdout)

Affects namespaces: `risingwave-2`, `risingwave`, `risingwave-2-operator-system`.

### 2. External exposure + ingress security

Why a pillar: the istio-ingressgateway is our public surface. New exposures here have the largest blast radius.

Proposed alert categories:
- New Service that becomes externally reachable (audit trail on `Service` + `VirtualService` creation)
- TLS posture issues (weak ciphers, downgrade, missing HSTS, cert chain anomalies)
- Suspicious source IPs hitting the gateway (threat-intel match)
- Unusual request patterns at L7 (scanning, brute force, injection signatures)

Not Wiz: HTTP 4xx/5xx rate, latency, gateway pod count. Those stay in Prometheus.

Affects namespaces: `istio-ingress`, `istio-system`, anything with a `VirtualService`.

### 3. Identity + secrets posture

Why a pillar: cluster's own credentials, RBAC, and SA bindings. Most attacks pivot here.

Proposed alert categories:
- Over-permissive RBAC (cluster-admin too widely granted, broad SA bindings)
- Secrets accessed by pods/SAs outside their intended consumer
- Default SA auto-mounted in pods that don't need API access
- Secrets exposed in env vars / config files / container images
- ExternalSecret sync failures that could leak placeholder values into prod

Not Wiz: cert-manager Certificate expiration / rotation. Prometheus owns that.

Affects: every namespace (RBAC + SA are cross-cutting). Concentration in `flux-system`, `external-secrets`, `cert-manager`, `kube-system`.

### 4. Compute integrity + control plane

Why a pillar: Talos worker + control plane are the foundation. Subversion here defeats everything above. Also catches noisy-tenant and resource-abuse patterns that look like attacks.

Proposed alert categories:
- Container escape / privilege escalation events
- Unexpected privileged containers / `hostPath` / `hostNetwork` additions outside known baseline (`istio-ingressgateway`, Cilium, kube-system DaemonSets)
- Suspicious syscalls / fileless attack patterns
- Talos control plane integrity — anomalous etcd access patterns, API server unusual calls
- Compute patterns that look like crypto-mining or DoS (distinct from normal scaling, which Prometheus owns)

Not Wiz: routine CPU/memory pressure, node-not-ready, pod count drift. Those stay in Prometheus.

Affects: all worker + control plane nodes (Talos).

---

## Prereqs (blocking deployment)

| # | Item | Owner | Status |
|---|---|---|---|
| 1 | Confirm `wiz.io` egress endpoints from worker subnet `10.10.82.0/24` (DNS, IP ranges, ports) | Steve Vives → Steve Duck | Pending |
| 2 | Decide sensor install pipeline — vendored Helm chart via Flux (matches platform stack) vs Wiz's own installer | Steve Vives + Doke | Pending |
| 3 | Define RBAC for the Wiz controller (scoped namespaces vs cluster-wide) | Steve Vives + Doke | Pending |
| 4 | Confirm sensor sidecar / kernel module requirements vs Talos restrictions (Talos is immutable + locked-down) | Steve Vives | Pending |

## Coordination

- **Doke (on-prem platform):** drives this onboarding, owns alert pillar definitions, integrates Wiz with Flux/Helm pattern.
- **Steve Vives (Wiz / security tooling):** Wiz expert. Confirms which alert categories Wiz delivers, owns sensor install, owns egress firewall ask.
- **Steve Duck (networking):** consulted on `wiz.io` egress firewall, no policy changes expected on his side.
- **Brendan Buschel (CySec):** consulted on alert routing + on-call rotation. Receives findings during pilot.

Cadence proposal:
- 20-min walkthrough call between Doke + Vives (this week) to confirm pillars + scope.
- Async follow-ups in this repo via PRs + issues.
- Working session (1–2 hr) to deploy sensors once prereqs clear.

---

## Status

- **2026-06-02:** Repo + Jira created. README v1 drafted. DM to Vives queued (sent separately).
- **Next:** Vives walkthrough; pillar confirmation; egress ask filed.

## Tracking

- **Umbrella ticket:** [INFRA-1513](https://usxpress.atlassian.net/browse/INFRA-1513) (Epic under INFRA-472)
- **Parent initiative:** [INFRA-472](https://usxpress.atlassian.net/browse/INFRA-472) (Dev Ops Enhancements)
- **Related:** [INFRA-1505](https://usxpress.atlassian.net/browse/INFRA-1505) (original DM ask, now folded into this onboarding)
- **Source decisions:** 2026-05-29 networking + CySec sync (internal review doc)

## References

- Wiz docs: https://docs.wiz.io/
- USXpress on-prem cluster (op-usxpress-dev) memory note: `istio_mesh_exportto_rca_jun02.md`
- Prometheus baseline alerts: [iaac-talos-flux-platform PR #24](https://github.com/variant-inc/iaac-talos-flux-platform/pull/24)
- Source-CIDR allow-list (Round 2 hardening): [INFRA-1496](https://usxpress.atlassian.net/browse/INFRA-1496)
- Cert chain (Phase 0 cert-manager + LE): [INFRA-1493](https://usxpress.atlassian.net/browse/INFRA-1493)

---

> Maintainer: Doke (on-prem platform). Open an issue or PR with proposed alert categories or pillar adjustments.

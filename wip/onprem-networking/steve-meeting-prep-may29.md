# Networking team meeting prep — 2026-05-29

**Attendees (expected):** Steve Duck (networking), Brendan Buschel (Cyber Security), Steve Vives (kube configs / security), Doke.

**Goal:** Walk through the TCP/SNI ingress design + security model, get sign-off on LE PROD as the CA, align on subzone delegation + audit-log destination + CIDR list, unblock Phase 1.

**Tone:** Show evidence (already shipped to dev), invite scrutiny, drive specific decisions out of the meeting.

---

## 60-second opener

> "Thanks for making time. We're standing up production-grade ingress on the on-prem dev cluster — HTTP DNS proven a week ago, HTTPS plane shipped end-to-end today. Next phase is TCP/SNI for non-HTTP wire protocols (psql, mongo, redis, mysql). I want to walk through the security model, confirm a couple of decisions you flagged, and align on what — if anything — the networking team owns on the critical path. **TL;DR: no BGP, no MetalLB, no firewall asks. Sub-zone delegation is the one place I genuinely need you.**"

---

## Status snapshot (what's already live)

| Layer | State | Evidence |
|---|---|---|
| HTTP DNS | Live since 2026-05-19 | `HTTP/1.1 404 from istio-envoy` reachable on `*.op-dev.usxpress.io` |
| cert-manager + IRSA chain | Live since today AM | IAM role `cert-manager-op-usxpress-dev` chains into `iaac-route53-zone` |
| LE staging + LE PROD ClusterIssuers | Ready=True | Smoke cert issued in 2m27s |
| Wildcard `*.op-dev.usxpress.io` cert | Live | `Let's Encrypt YR1`, valid through 2026-08-26 |
| Per-team depth-N cert pattern | Proven today PM | `*.brands.op-dev.usxpress.io` issued, mounted, served real TLS 1.3 + HTTP/2 to `api.brands.op-dev.usxpress.io` from corp VPN |
| Istio gateway DS | 7/7 Ready | (fixed an 8-day-old istiod over-reservation in the same session) |
| Mesh PKI (istio-csr) | Untouched throughout | RW workloads Running=True before AND after every change |

**Headline:** No BGP, no MetalLB, no network team coord needed for the cert chain. The Route53 trust pre-arrangement (`extd-usxpress-io-*` + `cert-manager-*` wildcard) cut what would have been a 5-day handoff to zero.

---

## Security model (for Steve Vives + Brendan)

**Layered controls** — by design, no single point compromises end-to-end posture:

| Layer | Control | Status |
|---|---|---|
| **Network reach** | corp VPN CIDR allow-list via `CiliumNetworkPolicy` on gateway pods | Phase 3 of INFRA-1492 (~1 PR) |
| **TLS in transit** | LE PROD certs, TLS 1.3, forward-secret cipher suites, 90-day auto-rotation via cert-manager | Live today |
| **Cert authority** | LE PROD via ACME DNS-01; backup path AWS PCA in <1hr (ClusterIssuer config swap) | Live |
| **Server identity** | Per-team wildcards bounded to a single team domain (`*.brands.*`) — blast radius limited | Live |
| **Backend auth (who you are)** | App-native: psql SCRAM-SHA-256/LDAP, mongo SCRAM, redis AUTH | Owned by app teams; unchanged |
| **Backend authz (what you can do)** | App-native: `pg_hba.conf`, RW roles, mongo roles | Owned by app teams |
| **mTLS at gateway** (opt-in) | Istio `PeerAuthentication` STRICT per sensitive port; client cert from private CA | Designed; per-service decision |
| **Audit** | Envoy access log per TCP session + per-protocol backend audit (pgaudit, mongo audit) | Phase 4; needs Steve Vives input on destination |
| **Rate / DoS** | Envoy `connection_limit` per source IP | Designed |
| **Secret encryption at rest** | k8s Secret encryption via Talos `EncryptionConfiguration` | Separate workstream; flag |
| **RBAC for cert-manager** | IRSA OIDC scoped to ONE SA (`cert-manager/cert-manager`) on ONE role-name pattern (`cert-manager-*`) | Live |

### Threat model — what this stops

- Random internet probing → cluster TCP: blocked at corp VPN + CIDR allow-list
- Plaintext credential capture on VPN: TLS 1.3 end-to-end (passthrough for TCP)
- Malicious VPN client port-sweeping: gateway only binds ports we explicitly declare
- Compromised IRSA token: trust scoped to one SA name + one role pattern; token TTL 1h
- Stolen LE cert from one team: blast radius is one team domain, not cluster-wide

### What this doesn't stop (admit upfront)

- App-layer SQL injection / abuse — that's the backend's problem (pgaudit, RW resource limits, app code)
- L7 DDoS beyond Envoy's per-IP connection limit — needs perimeter firewall / corp VPN concentrator rate limit
- Compromised network admin who can issue arbitrary certs — mitigated by Route53 trust scoping but not eliminated

---

## Decisions I'm driving out of the meeting

1. **LE PROD vs AWS PCA: confirm LE.** Brendan already said "no issues with LE, simpler" — get the formal nod. Decision drives nothing new; just removes the open question from the design.

2. **Subzone delegation for `op-dev.usxpress.io`.** Today the wildcard trust on `iaac-route53-zone` already works for us, but formal subzone delegation tidies ownership ("on-prem team owns op-dev.usxpress.io exclusively"). Steve Duck's call on timing.

3. **Corp VPN CIDR ranges** for the gateway allow-list. Need the list, who maintains it, expected rate of change. Drives Phase 3 (INFRA-1496) NetworkPolicy.

4. **Audit log destination** (Splunk / Sumo / Datadog / other) for Phase 4. Steve Vives likely has standards. Drives Phase 4 (INFRA-1497).

5. **mTLS at the gateway** for sensitive TCP endpoints (write-path psql, mongo): phase-in plan or defer? Steve Vives input.

6. **Pod Security Standards** posture across the platform namespaces (`istio-ingress`, `cert-manager`, `risingwave-2`): we currently use `baseline`/`restricted` per ns. Steve Vives may want to escalate to all-restricted.

7. **Approval to proceed with Phase 1** (TCP/SNI listeners, INFRA-1494). All prerequisites met; ready to ship next.

---

## Anticipated questions + ready answers

**Q (Steve V):** "Why not put a WAF in front?"
**A:** TCP/SNI is by-design passthrough — a WAF would terminate TLS and break the model. WAF makes sense for HTTP-only flows; we'd add one for that plane separately (out of current scope; nothing prevents it). For TCP/SNI we rely on backend auth + CIDR allow-list + L4 TLS.

**Q (Steve V):** "Why wildcard certs vs per-host?"
**A:** Per-team wildcards (`*.brands.*`) limit blast radius to one team domain — better than per-host operationally (4 certs/week LE rate limit when issuing many) and not appreciably weaker than per-host security-wise (a compromised cert affects only that team's hostnames either way). Per-host is available if Steve V wants it for a specific high-sensitivity service.

**Q (Brendan):** "What if LE has an incident?"
**A:** 90-day certs give ~75-day expiry buffer. ClusterIssuer swap to AWS PCA is a single PR (config change); no architectural rework. Designed for hot-swappable CA.

**Q (Steve V):** "Compromised IRSA token — blast radius?"
**A:** Trust limited to ONE ServiceAccount (`cert-manager/cert-manager`) via OIDC; tokens TTL 1h; assume-role chain ends at `iaac-route53-zone` which only does Route53 ops on the specific zone. Can rotate by deleting + reapplying IAM role via TF (<5 min).

**Q (Steve V):** "Backend TLS — what does the client see?"
**A:** With passthrough, the **backend** terminates TLS, so clients see the backend's cert (not the gateway's). For psql/RW that means we deploy cert-manager Certificates onto the RW frontend pods in Phase 2 (INFRA-1495). Backend pods serve their own cert.

**Q (Steve V):** "Where do private keys live?"
**A:** k8s Secrets in `istio-ingress` ns (gateway side) and the backend's ns (backend-terminated). Talos `EncryptionConfiguration` for at-rest encryption is a separate workstream — flagging it as a known follow-up. Happy to fast-track if it's a meeting-output ask.

**Q (Steve V):** "RBAC on cert-manager Certificate resources?"
**A:** Today: platform team writes via Flux PRs. App teams don't directly create Certificates. Future option: per-namespace RBAC for app-team self-service Certificates if that's desired.

**Q (Steve D):** "Anything blocking that needs my team?"
**A:** Just sub-zone delegation, and only if you want the cleanup. We can defer indefinitely if you prefer.

**Q (Brendan):** "How do we monitor cert expiry?"
**A:** cert-manager Prometheus metrics + Alertmanager rule on expiry <14d. Plan to wire into the platform alerting destination once it's defined (Phase 4 / 5).

---

## What I'm NOT going to over-pitch

- I'm NOT going to bash MetalLB / BGP — they're legitimate options I picked NOT to need
- I'm NOT going to dismiss the network team — Steve Duck owns sub-zone delegation
- I'm NOT going to claim Phase 1 is shipped when it isn't — drafts only

---

## Links to have open during the meeting

- **Design doc:** [`docs/designs/tcp-sni-ingress-design.md`](../../docs/designs/tcp-sni-ingress-design.md) (on damoke012/eks_code)
- **Jira umbrella:** [INFRA-1492](https://usxpress.atlassian.net/browse/INFRA-1492) (under Epic [INFRA-1499](https://usxpress.atlassian.net/browse/INFRA-1499) under Initiative [INFRA-472](https://usxpress.atlassian.net/browse/INFRA-472))
- **Phase 0 PR closure:** [INFRA-1493](https://usxpress.atlassian.net/browse/INFRA-1493) (Done with full audit trail)
- **Cert chain demo (live):** `curl -sIv https://api.brands.op-dev.usxpress.io | grep -iE "subject|issuer|HTTP/"` (if you have time + network reach)

---

## After the meeting — what I should write down

- LE PROD: approved / additional asks
- Subzone delegation: agreed timing / not needed
- Corp VPN CIDR(s): list + owner
- Audit log destination: <destination>
- mTLS-at-gateway: defer / phase-in plan
- PSS posture: any escalation asked
- Phase 1 approval: yes / conditions
- Anyone else they want looped in

---

## If asked "what do you need next"

In order:
1. The CIDR list (gates Phase 3)
2. Audit log destination (gates Phase 4)
3. mTLS-at-gateway position from Steve V (defer or phase in)
4. Green light to ship Phase 1 (no dependencies — purely informational)

Subzone delegation can be a parallel workstream and doesn't gate anything technical.

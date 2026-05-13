# Draft Teams message to Steve Duck — On-prem networking direction (May 13 2026)

**Status**: DRAFT, not yet sent. Awaits Dare's review before sending.

**Context**:
- Dare back from PTO May 12
- Vibin still out
- Cluster survey done morning of May 13
- hostNetwork test validated viability of Istio ingressgateway-on-workers approach
- Three pieces of work proposed to close the gap

---

## Message body (paste into Teams DM to Steve)

> Hi Steve — quick update on on-prem networking now that I'm back from PTO and have ground truth.
>
> **Cluster state (on-prem `op-usxpress-dev`)**: Istio control plane is already deployed and healthy (21d uptime). Five Istio VirtualServices are already defined (`api.brands.dev.usxpress.io`, `api.driver.attrition.dev.usxpress.io`, etc.) — they were templated from cloud, waiting on the data plane.
>
> **The gap**: we never deployed the Istio ingressgateway data plane. Without it, every service needing external reach gets a `kubectl expose --type=NodePort` workaround. RisingWave namespace alone has three NodePort services (`frontend-lb:32567`, `pg-postgresql:32546`, `risingwave-console:32114`) — each a different `10.10.82.x:32xxx` combo with no DNS, no HTTPS. Tim's been working around this during the last week.
>
> **The fix (validated today)**: Deploy istio-ingressgateway as a DaemonSet with `hostNetwork: true` on worker nodes. I tested this on the cluster this morning — bound a test pod to worker IP `10.10.82.26:8080`, hit it from VPN via `curl`, full HTTP round-trip. Worker IPs are already VPN-routable (you proved that with kubectl access; today's test reproves it at the application layer). So no network-team coordination required.
>
> **Three pieces, ~2-3 days of platform work**:
>
> 1. **istio-ingressgateway** DaemonSet on worker hostNetwork. New namespace `istio-ingress` (sibling of `istio-system`), proper PSA labels, listens on ports 80/443 of every worker IP. **Additive** — does not modify any existing service. RW's current NodePort access keeps working.
> 2. **external-dns** with Route53 integration (ticket ONPREM-25 already scoped) — app teams get `https://service.dev.usxpress.io` instead of raw IPs.
> 3. **cert-manager ClusterIssuer** for the public DNS zone — Let's Encrypt or internal CA, depending on whether the domain is internet-resolvable.
>
> Once those land, app teams apply a Service + VirtualService manifest exactly like cloud — same developer UX, no port-forward, no NodePort sprawl. The 5 existing orphan VirtualServices light up automatically.
>
> **Risk management**: documented protection rule — any change on `op-usxpress-dev` must not affect running RW. Pre/post-flight checks (`kubectl get rw`, pod health, psql round-trip) every deploy. Today's hostNetwork test validated this — RW state unchanged before and after.
>
> **What this doesn't solve**: non-HTTP services (raw TCP like RW SQL on 4567). They keep using NodePort until BGP. Smaller surface; lower urgency. I'll keep the network-team ask drafted as a P2.
>
> Want to align on prioritization? Could start next week if you agree.

---

## Pre-send checklist

- [ ] Confirm `10.10.82.x` IP ranges in the message are correct
- [ ] Mention any specific stakeholders Steve should loop in (Vibin when back? observability team for OTel?)
- [ ] Cut detail if Steve prefers shorter messages — could compress to 4 paragraphs
- [ ] Decide on the timing ask ("Could start next week if you agree" — adjust if Steve isn't back by then)

## Related artifacts

- Backup network-team-ask (P2): `risingwave_iaac_artifacts/network-team-ask.md`
- Protection rule: `memory/feedback_protect_rw_onprem_workload.md`
- hostNetwork proof: `memory/onprem_hostnetwork_ingress_proof.md`
- Gap analysis: `memory/onprem_networking_gap_may13.md`
- ONPREM-25 (external-dns ticket): tracked in `jira_tickets_remaining.md`

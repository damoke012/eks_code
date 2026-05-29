# Network team ask — VPN-routable LoadBalancer IPs for op-usxpress-dev

**Owner**: Cloud Platform team (Dare)
**Audience**: USXpress Network team
**Status**: drafted; to send post-PTO (week of May 12)

---

## TL;DR

Our on-prem Kubernetes cluster `op-usxpress-dev` (subnet `10.10.82.0/24`, on-prem Talos)
needs to expose internal services on stable LAN IPs that USXpress VPN clients can reach.
Cilium's L2/ARP LoadBalancer announcement works in-cluster but doesn't reach VPN clients
because VPN traffic is routed in from a different segment and ARP doesn't cross routers.
We're working around with NodePort, but we'd like proper LB routing for cleaner UX.

**Ask**: BGP peering between Cilium on cluster worker nodes and the corporate router,
OR static routes from the corporate router for our LB pool to the worker IPs.

Not urgent — NodePort works. But would unblock cleaner external access for RisingWave
and any future internal-facing services.

---

## Problem statement (what we observed)

- Cluster runs Cilium CNI with **L2/ARP-based** LoadBalancer announcements (config explicitly
  notes "no BGP on-prem" — that's a deliberate trade-off when there's no peering established).
- Cilium L2 announces a LB Service IP via gratuitous ARP within the cluster's L2 segment.
- Tested 2026-04-30: a LB Service at `10.10.82.221` was reachable from inside the cluster
  (via a debug pod) but timed out from a corp laptop on USXpress VPN.
- The path:
  - WSL → Windows VPN → corp router → cluster subnet
  - The corp router can't ARP-resolve `10.10.82.221` because the announcement is L2-only
  - Result: "Destination Host Unreachable" from a router IP in `10.10.82.0/24`
- API VIP at `10.10.82.50` works from VPN — that's because it's announced via Talos's
  own VRRP/keepalived at a level your network already accommodates. Cilium's LB IPs are
  a different mechanism.

## Pivot we made

Switched the affected Service to `type: NodePort`. Worker IPs (`10.10.82.26, 27, 28, 178, 180`)
are routable from VPN today, and Talos workers allow NodePort, so this works:
```
psql -h 10.10.82.26 -p 32567 -d dev -U root
```

NodePort high-port numbers are user-visible (32567 vs 4567) and there's no stable single
LB IP. Functional, not ideal long-term.

## What we want

Allow `Service: type: LoadBalancer` IPs assigned by Cilium from the configured pool to be
**routable from USXpress VPN**.

### Option 1 — BGP peering (preferred, most flexible)

Cilium runs a BGP daemon on cluster workers. Peers with the corporate router(s). Announces
LB pool IPs as BGP routes. Router learns and forwards traffic.

**What we'd need from networking**:
- Router IP(s) to peer against (likely the gateway for `10.10.82.0/24`)
- Cluster ASN to use (a private ASN like `64512` is fine)
- Your router's ASN
- Approval for BGP peering on those router IPs
- (Optionally) a route-map filter limiting accepted advertisements to a pre-agreed range —
  e.g., we'd only announce `10.10.82.220/29` (8 IPs); your router rejects anything else from us

**What you get**:
- Visibility into what we announce (BGP table inspection)
- Authoritative control via filters; we can't announce arbitrary IPs

### Option 2 — Static routes (simpler, less flexible)

Static routes on the corporate router pointing the LB pool range to the worker IPs (with
ECMP across all five workers, or to one with the others as backup).

**What we'd need from networking**:
- Static route: `10.10.82.220/29` → next-hops `10.10.82.26, .27, .28, .178, .180` (ECMP)

**Trade-off**:
- Faster to implement, no BGP daemon needed
- Manual updates if pool expands or workers change IPs
- No automatic failover beyond ECMP

### Option 3 — L2 stretch / VLAN extension

Generally not recommended (security and broadcast domain implications). Listed only for
completeness.

## Cluster details for your reference

| Item | Value |
|---|---|
| Cluster name | op-usxpress-dev |
| Cluster subnet | 10.10.82.0/24 |
| API VIP (already routable from VPN — please don't change this) | 10.10.82.50:6443 |
| Worker node IPs (BGP speakers / static-route targets) | 10.10.82.26, .27, .28, .178, .180 |
| Control plane node IPs (do NOT advertise from these — Talos blocks NodePort there too) | 10.10.82.29, .179, .181 |
| Existing Cilium LB pool range | 10.10.82.20-254 (per `CiliumLoadBalancerIPPool dpl2-lb-pool`) |
| Range we'd want announced (constrainable) | 10.10.82.220-228 (8 IPs) — adjustable |
| CNI / LB mechanism | Cilium with L2 announcements today; can add BGP via `CiliumBGPPeeringPolicy` |
| In active use today on the LB pool | Octopus worker LB at 10.10.82.220 (in-cluster only currently) |

## Use cases driving this

- **RisingWave** SQL endpoint for app team development & BI tools — currently exposed on NodePort
- **Future internal-facing services** that benefit from stable LAN-routable VIPs
- **Any team-shared dev tooling** behind a fixed address

## What we won't ask for (scope guardrails)

- Public/internet-routable IPs — we want **VPN-only** reach
- Ingress for HTTP services from the internet — different problem (reverse proxy / cloud LB)
- Any change to the API VIP (`10.10.82.50`) — already works, leave it alone

## Suggested next step

A 30-min call to walk through the request, agree on Option 1 vs 2, and identify what
network-side config is needed. Happy to bring our Cilium and Talos networking specifics
to make the conversation concrete.

## Reference (technical)

If Option 1, the Cilium BGP config we'd add:

```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPPeeringPolicy
metadata:
  name: corp-router-peering
spec:
  nodeSelector:
    matchExpressions:
      - key: node-role.kubernetes.io/control-plane
        operator: DoesNotExist
  virtualRouters:
    - localASN: 64512
      exportPodCIDR: false
      neighbors:
        - peerAddress: <corp-router-ip>/32
          peerASN: <your-asn>
      serviceSelector:
        matchLabels:
          role: external-access
```

We'd narrow `serviceSelector` so only Services we explicitly opt-in (`role: external-access`)
are announced.

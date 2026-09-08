# Reply to Idris — 2026-09-08 — "where did Tim post his IP?"

Idris — Tim's address is `172.17.13.100/24`, gateway `172.17.13.254`, corp DNS
`10.10.90.10 / 10.9.222.10 / 10.10.90.9`, search domain `usxpress.com`. Dell dock,
DHCP, macOS.

But I do not think an IP is what you need, for two reasons.

**1. There is no IP allow-list deployed, so nothing is rejecting him by address.**
The source-CIDR allow-list is INFRA-1496, Phase 3 of the TCP/SNI ingress work. It is
still `filed` — there is no `CiliumNetworkPolicy` in `istio-ingress` on any cluster, and
none in the drafts either (`iaac-drafts/onprem-tcp-sni-ingress/` has the Gateway and the
VirtualServices, Phases 1-2, and no policy). Adding Tim's address today changes nothing,
because there is nothing for it to be added to.

**2. If you are building 1496 now, one laptop's DHCP lease is the wrong input.**
`172.17.13.100` is a lease. It changes. An allow-list built from it locks Tim out the
next time he docks, and locks out everyone else immediately. The ticket's own step 2 says
to get the corp VPN CIDR list from the network team (Steve), and to start generous and
narrow later. That list is what Phase 3 needs, not a host address.

Also worth knowing before it costs you an afternoon: the ticket flags that the gateway
runs `hostPort` on a DaemonSet, so packets arrive on the worker's NIC. Whether Cilium
enforces policy on hostPort traffic at our version is unverified — stage a throwaway
policy on an unused port before writing the real one, or the negative test will look
like a policy bug when it is an enforcement gap.

## What we measured today, from a machine on the VPN

op-usxpress-dev is healthy from a working client:

| | |
|---|---|
| `10.10.82.50:6443` | open |
| `rw2-sql.op-dev.usxpress.io:4567` | open |
| `rw2-dashboard` / `risingwave-dashboard` | HTTP 200 |
| `rw2-pg.op-dev.usxpress.io` | **no DNS record** — expected, `rw2-pg-passthrough.yaml` was never applied (INFRA-1495) |

So if Tim reported he could not reach the environment, it is client-side, not the
platform, and not an allow-list. `scripts/triage-user-cluster-access.sh` in eks_code
separates network from credential from permission in one run; he can run it on his Mac
when he is back.

## Two things on our side

- Tim is **on vacation**, so nothing here is urgent.
- He now has namespace super-user on `risingwave-2` and `risingwave` on op-dev
  (RoleBindings applied and boundary-tested; PR to the `op-dev` branch to follow). He has
  no certificate yet — that is the ten minutes of work waiting for his return.

One open question back at you: did Tim say he wanted **kubectl**, **psql**, or the
**dashboard**? The Phase 1 record has his path as psql plus the dashboard with kubectl
explicitly excluded, and the three have completely different fixes.

— Dare

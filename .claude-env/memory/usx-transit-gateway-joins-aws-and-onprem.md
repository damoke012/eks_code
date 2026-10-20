---
name: usx-transit-gateway-joins-aws-and-onprem
description: "tgw-09c7b37043d31e43a (USX Infrastructure Transit Gateway, network account 155768531003) attaches all three EKS VPCs, 2 peerings and a live VPN — so AWS and the datacenter are already joined, and the EKS VPCs route 10.0.0.0/8 into it"
metadata:
  type: project
---

**Measured 2026-10-20** while chasing whether on-prem could reach a MongoDB Atlas PrivateLink
endpoint ([[atlas-privatelink-may-not-reach-onprem]]).

**`tgw-09c7b37043d31e43a`** — *"USX Infrastructure Transit Gateway"*, owner
**155768531003** (the network account), state `available`, us-east-2. Attachments:

| Type | Count | Owners seen |
|---|---|---|
| `vpc` | 7 | 108141096600, 494141260463 (×2), **700736442855 (EKS dev)**, 247782343222, **937464026810 (EKS prod)**, **527101283767 (EKS QA)** |
| `peering` | 2 | 108141096600, 786352483360 |
| **`vpn`** | **1** | 155768531003 |

Two VPN connections exist in **network / us-east-2**, both `available`:
`vpn-0c11da6eb9db9c8c2` and `vpn-055c203c2afb11482`. **No Direct Connect** was found in
us-east-1 or us-east-2 in the network or mgmt accounts.

**The prod EKS VPC `vpc-089f99053feed0cad` (10.16.0.0/20) routes:**

```
10.16.0.0/20    local
10.0.0.0/8      tgw-09c7b37043d31e43a      <- on-prem 10.10.82.x falls in here
172.17.0.0/16   tgw-09c7b37043d31e43a
192.168.0.0/16  tgw-09c7b37043d31e43a
0.0.0.0/0       i-03d3e197f9b482e22        <- a NAT/firewall INSTANCE, not a NAT gateway
```

**Why this matters beyond one app.** The assumption that on-prem and AWS are separate islands
reachable only over the public internet is **wrong**: a TGW with a live VPN attachment already
joins them, and every EKS VPC is on it. Any "we cannot reach that from on-prem" claim has to
be measured against this, not assumed.

⚠️ **Still unconfirmed, and all three are needed before a path actually works:**

1. the **TGW route table** must carry a route covering the on-prem CIDR pointing at the VPN
   attachment, and the VPC's attachment must be associated with that route table;
2. the **on-prem side** must route the AWS CIDR (e.g. 10.16.0.0/20) back over the VPN;
3. the **destination security group** must admit the on-prem CIDR. For the Atlas endpoint,
   `sg-0c8f8db29b16a1477` currently allows TCP from **10.16.0.0/20 only**, so on-prem is
   refused there regardless of routing.

⚠️ The default route leaves through an **EC2 instance**, so egress and ingress policy may also
be enforced by an appliance rather than by security groups alone.

Related: [[onprem-ingress-dns-convention]], [[qa-vs-dev-delta]], [[one-account-one-cluster-assumption]].

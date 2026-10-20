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

✅ **TGW routing confirmed.** The TGW has **8 route tables**, and **every one of them**
carries `10.0.0.0/8 active propagated` from the **vpn** attachment
`tgw-attach-02049e22560f04685`. That includes `tgw-rtb-0beb19052b379bed1`, the table the prod
VPC's attachment is actually associated with — which is the one that governs traffic leaving
that VPC, and is **not** the table a `[0]` index returns.

Five of the eight also carry `10.16.0.0/20 propagated vpc`. The three without it
(`09edb68a`, `0beb1905`, `0d368e8e`) do not need it: the prod VPC reaches its own CIDR
through its local route, not through the TGW.

⚠️ **Read a TGW route table by the attachment's ASSOCIATION, never by index.** Searching
`TransitGatewayRouteTables[0]` returned a table the prod VPC does not use. Here every table
happened to agree, so the shortcut produced the right answer for the wrong reason — which is
how it survives to the day it does not.

⚠️ **Still unconfirmed:**

1. the **on-prem side** must route 10.16.0.0/20 back over the VPN. The datacenter advertises
   10.0.0.0/8, so it believes it owns AWS's range too; this only works if it is *receiving*
   AWS's more specific 10.16.0.0/20 and preferring it by longest prefix. Not readable from
   AWS — ask the network team, or measure it with a connection.
2. the **destination security group**. For the Atlas endpoint, `sg-0c8f8db29b16a1477` allows
   TCP from **10.16.0.0/20 only**, so on-prem is refused there regardless of routing. This is
   a definite, known change.

⚠️ The default route leaves through an **EC2 instance**, so egress and ingress policy may also
be enforced by an appliance rather than by security groups alone.

Related: [[onprem-ingress-dns-convention]], [[qa-vs-dev-delta]], [[one-account-one-cluster-assumption]].

## On-prem addressing, measured 2026-10-20

| | |
|---|---|
| **Node / machine addresses** | **10.10.82.0/24** — op-qa's 13 nodes are .23 .24 .25 .30 .105 .106 .107 .138 .139 .177 .182 .183 .184, and op-dev (.50) and op-prod (.52) sit in the same /24 |
| **Pod network** | **10.244.0.0/16**, allocated as a /24 per node |

**One /24 covers all three on-prem clusters**, which is what a firewall rule should name.
Pods leave the cluster masqueraded to their node's address, so **10.244.x.x is not what a
remote service sees** — naming the pod CIDR in a firewall request gets a rule that never
matches, and AWS would have no return path for it anyway.

## The thing that owns a security group may not be the team you expect

`sg-0c8f8db29b16a1477`, guarding the MongoDB Atlas interface endpoint in 937464026810, is
tagged:

```
octopus/project        mongodb
octopus/space          USXpress
octopus/project_group  enterprise
octopus/environment    production
octopus/release_channel release
```

So it is deployed by an **Octopus project in the `USXpress` space** — not by the platform
team's Terraform, and not by `iaac-octopus-config`, which manages only `Default` and `DevOps`
([[octopus-config-builds-the-stage-not-the-play]]). **Read a resource's tags before assuming
who changes it.** And because it is an Octopus Terraform project, the deployment will report
Success after printing a plan it did not apply — require `Apply complete!`
([[octopus-green-but-no-apply]]).

Its description is *"open within VPC"*: admitting an outside network is a posture change its
owner agrees to, not a mechanical edit.

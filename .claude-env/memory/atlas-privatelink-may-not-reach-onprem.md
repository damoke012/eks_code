---
name: atlas-privatelink-may-not-reach-onprem
description: "CONFIRMED 2026-10-20: mongodb-pl-0.1cr18.mongodb.net is an AWS interface endpoint in us-east-2 resolving to 10.16.x.x on ports 1024-1026, so a lifted app has no route to its database. Public DNS already returns the private IPs, so the gap is routing, not DNS"
metadata:
  type: project
---

✅ **CONFIRMED the same day it was raised**, by resolving the name through public DNS
(Google DoH) from outside any USX network:

```
SRV -> pl-0-us-east-2.1cr18.mongodb.net  ports 1024, 1025, 1026   (NOT 27017)
A   -> CNAME vpce-06e6cad5b697c515a-46v8hwmn.vpce-svc-07a355fc8047ca10d.us-east-2.vpce.amazonaws.com
    -> 10.16.6.113, 10.16.11.221, 10.16.8.87
TXT -> authSource=admin&replicaSet=atlas-qy8w3t-shard-0
```

It was filed as a hypothesis for one turn, then measured. **Ports 1024-1026 are the Atlas
private-endpoint form** and are the quickest tell; a firewall request naming 27017 would be
approved and would not help.

⚠️ **AWS returns those private addresses to PUBLIC DNS queries**, so hybrid-DNS work (Route 53
inbound resolvers, conditional forwarding) is **not** needed. The gap is **routing** plus the
endpoint's security group — and the failure mode is therefore a **timeout at connect**, which
reads like a firewall fault rather than an architecture one.

**Still unmeasured:** whether the on-prem site has any route to 10.16.0.0/16.

**Measured part.** `pricing-rfp-handler` in cloud EKS prod connects to
`mongodb+srv://mongodb-pl-0.1cr18.mongodb.net/?authSource=$external&authMechanism=MONGODB-X509`
— X.509 client-certificate auth, no password in the URI, four TLS files delivered in the
secret `pricing-rfp-handler-m-u`.

**The inference.** In Atlas, a `-pl-` hostname is the **PrivateLink** connection form; it
resolves to private addresses inside the VPC that owns the endpoint. On-prem is not in that
VPC. If that holds, an application lifted on-prem **has no network path to its own database**,
and no amount of credential work fixes it.

**The test** is a TCP connection to one of those addresses on **1024**, from a pod on
**op-dev** (never a prod cluster). `getent hosts` proves nothing here: the A record resolves
perfectly well, to addresses with no route.

**Three ways out**, researched against primary sources in
`wip/onprem-app-cicd/RESEARCH-atlas-from-onprem-2026-10-20.md`:

* **A — the standard public connection string + the on-prem egress on the IP access list.**
  A private endpoint does **not** remove a cluster's standard connection string unless
  **Private Only** mode is on, and X.509 auth is independent of the network path, so the same
  certificates work. Hours of work, no network engineering, wider internet exposure.
* **B — reach the existing endpoint over Direct Connect or VPN.** AWS supports this; since DNS
  already answers, it reduces to a route to 10.16.0.0/16 and a security-group rule on
  1024-1026. Fixes it for every future workload at once.
* **C — a second Atlas private endpoint in a VPC the on-prem site already reaches.** Atlas
  allows several per project and region.

**The binary question that picks between them:** does on-prem have a route to the VPC holding
`vpce-06e6cad5b697c515a`?

**How to apply.** When lifting any cloud app on-prem, read its datastore hostnames **before**
anything else and look for VPC-scoped forms — PrivateLink, VPC endpoints, internal Route 53
zones. A hostname that works everywhere in cloud can be unroutable from on-prem while every
credential is perfect.

Related: [[onprem-app-cicd]], [[envfrom-hides-the-inventory]], [[ask-the-registry-not-the-resolver]].

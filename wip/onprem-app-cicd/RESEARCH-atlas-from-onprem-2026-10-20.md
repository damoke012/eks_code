# Reaching MongoDB Atlas from on-prem — measured, and the three ways out

**2026-10-20.** Raised by `pricing-rfp-handler`, but **this is not an app-specific problem**:
any cloud application lifted on-prem that uses Atlas over a private endpoint hits it. Decide
it once, as a platform standard, not per app.

## Measured, not inferred

Resolved from public DNS (Google DoH), so no corporate resolver was involved:

```
SRV  _mongodb._tcp.mongodb-pl-0.1cr18.mongodb.net
  -> pl-0-us-east-2.1cr18.mongodb.net  ports 1024, 1025, 1026
TXT  mongodb-pl-0.1cr18.mongodb.net
  -> authSource=admin&replicaSet=atlas-qy8w3t-shard-0
A    pl-0-us-east-2.1cr18.mongodb.net
  -> CNAME vpce-06e6cad5b697c515a-46v8hwmn.vpce-svc-07a355fc8047ca10d.us-east-2.vpce.amazonaws.com
  -> 10.16.6.113, 10.16.11.221, 10.16.8.87
```

Three readings:

1. **Ports 1024-1026, not 27017.** That port range is the Atlas **private endpoint** form.
2. **An AWS interface VPC endpoint**: `vpce-06e6cad5b697c515a`, service
   `vpce-svc-07a355fc8047ca10d`, region **us-east-2**.
3. **The addresses are RFC1918, in 10.16.x.x.** On-prem is 10.10.82.x. Different network.

✅ **DNS is already solved.** AWS returns the endpoint's private addresses to *public*
queries, which we just proved from outside any USX network. So the usual hybrid-DNS work —
Route 53 inbound resolver endpoints, conditional forwarding — **is not needed for this
name**. What is missing is **routing**, and the endpoint's **security group**.

❓ **Still unmeasured: whether on-prem has any route to 10.16.0.0/16.** Everything below
depends on that answer, and it is two commands away.

## The three ways out

### Option A — use the standard (public) connection string, allow-list the on-prem egress

MongoDB's documentation is explicit that a private endpoint **does not remove other access
paths**: every cluster keeps a standard connection string resolving to public addresses, and
IP access lists and peering continue to work alongside the endpoint. The exception is
**Private Only** mode, which forces private resolution — so the first thing to check is
whether this project has it enabled.

* **Work:** get the standard connection string from Atlas, add the on-prem site's egress
  addresses to the IP access list, point `values-<env>.yaml` at it.
* **Credentials are unaffected.** Authentication is X.509 client certificate; the network path
  does not change the auth mechanism, and the same four TLS files work.
* **Cost:** none. **Time:** hours, and most of it is waiting for an Atlas admin.
* **Against it:** traffic crosses the internet, and it widens the cluster's exposed source
  list. Whether that is acceptable is a security decision, not a technical one.

### Option B — reach the existing endpoint over Direct Connect or VPN

AWS supports reaching an interface endpoint from on-premises over Direct Connect or
Site-to-Site VPN. Since DNS already answers correctly, this reduces to:

1. a route from the on-prem site to **10.16.0.0/16** (Direct Connect or VPN, plus
   propagation through whatever transit gateway is in the path);
2. the VPC endpoint's **security group** permitting the on-prem CIDR on 1024-1026.

* **Work:** network engineering, and it depends entirely on a link already existing.
* **For it:** no new exposure, nothing changes in Atlas, and it fixes the problem for every
  future workload at once.
* **Against it:** it makes on-prem depend on an AWS network path, which runs against the
  stated goal that on-prem should stand alone.

### Option C — a second Atlas private endpoint, in a VPC the on-prem site already reaches

Atlas allows multiple private endpoints per project and region. If a route exists to some
*other* USX VPC but not to 10.16.x.x, put an endpoint there instead of re-plumbing the network.

* **Work:** one Atlas endpoint, one VPC endpoint, a security group.
* **Only makes sense if** option B's answer is "a link exists, but not to that VPC."

### Not an option

**Leaving Mongo in cloud while the app runs on-prem.** It would work, and it contradicts the
reason for the move: the application was brought on-prem because a dependency was unreachable
from cloud. Trading one unreachable dependency for another is not progress, and it makes the
on-prem instance permanently dependent on the cloud account.

## Deciding it

The question to answer first is **B's precondition**, because it is binary and it eliminates
either A or B's relevance immediately:

> Does the on-prem site have a route to the VPC holding `vpce-06e6cad5b697c515a`?

If **yes** → option B, and this stops being a project blocker.
If **no** → option A for this app now, with option B or C raised as the platform standard,
because the next lifted application will ask the same question.

## Proven

* `mongodb-pl-0.1cr18.mongodb.net` is an **AWS PrivateLink interface endpoint** in us-east-2,
  resolving to **10.16.6.113 / 10.16.11.221 / 10.16.8.87** on ports **1024-1026**.
* Those addresses are returned by **public** DNS, so hybrid-DNS work is not required.
* An Atlas cluster with a private endpoint **retains** its standard public connection string
  unless Private Only mode is enabled.
* An interface endpoint **can** be reached from on-prem over Direct Connect or VPN.
* The auth mechanism is X.509 and is **independent of the network path**.

## Tested and killed

* **"The hostname just fails to resolve from on-prem."** It resolves fine, publicly, to
  private addresses. The failure will be a **timeout at connect**, which reads like a firewall
  problem rather than an architecture one — and that is exactly how this would have been
  misdiagnosed in dev.

## Traps

* **A `getent hosts` test proves nothing here.** The name is SRV-based, and the A record
  resolves successfully to unroutable addresses. Only a TCP connection on 1024-1026 measures
  reachability.
* **Ports are 1024-1026, not 27017.** A firewall request naming 27017 will be approved and
  will not help.
* **Private Only mode** would invalidate option A. Check it before promising that route.
* **This is a platform decision wearing an application's clothes.** Solving it only for
  `pricing-rfp-handler` leaves the next application to rediscover it.

## Sources

* MongoDB, *Learn About Private Endpoints in Atlas* — https://www.mongodb.com/docs/atlas/security-private-endpoint/
* MongoDB, *Configure Private Endpoints* — https://www.mongodb.com/docs/atlas/security-configure-private-endpoints/
* MongoDB, *FAQ: Connection String Options* — https://www.mongodb.com/docs/atlas/reference/faq/connection-changes/
* AWS, *Access VPC resources through AWS PrivateLink* — https://docs.aws.amazon.com/vpc/latest/privatelink/privatelink-access-resources.html
* AWS, *AWS PrivateLink FAQs* — https://aws.amazon.com/privatelink/faqs/

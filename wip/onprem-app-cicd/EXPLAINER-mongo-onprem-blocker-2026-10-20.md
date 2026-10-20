# Why the pricing app can't reach its database from on-prem — and what fixes it

**2026-10-20.** Written for anyone who needs to act on this: the application team, the
network team, and whoever signs off the change. No prior context needed.

## In one line

The application's database only accepts connections from inside one specific AWS network,
and on-prem is not inside it — but the road between the two already exists, so this is a
firewall rule, not a new connection.

## What is actually going on

The `pricing-rfp-handler` application stores its data in **MongoDB Atlas**, a managed
database service. Atlas can be reached two ways: over the public internet, or through a
**private door** that only opens onto one particular AWS network.

US Xpress uses the private door. In practice that means the database's address
(`mongodb-pl-0.1cr18.mongodb.net`) does not point at a public server — it points at three
internal addresses, `10.16.6.113`, `10.16.11.221` and `10.16.8.87`, which live inside the
AWS network that hosts the cloud version of this application.

When the application runs in AWS, it is already inside that network, so it simply connects.
When the same application runs on-prem, it is somewhere else entirely — the datacenter, on
addresses beginning `10.10.82.` — and the private door does not know it.

**This is not a password problem.** The application proves who it is with a certificate, and
that certificate works from anywhere. The problem is purely about which network the
connection arrives from.

## The good news

We expected to find that on-prem and AWS were separate islands joined only by the public
internet. **They are not.** There is already a permanent, encrypted link — a VPN — between
the datacenter and AWS, and every relevant AWS network is attached to it.

We traced the whole path and it is complete:

| Step | Question | Answer |
|---|---|---|
| 1 | Does the AWS network know how to send traffic back to the datacenter? | **Yes** |
| 2 | Does the shared router in the middle know the route? | **Yes**, on all eight of its routing tables |
| 3 | Is that route coming from the datacenter link, or something else? | **From the VPN** — the datacenter itself |
| 4 | Can traffic from the datacenter find the database's door? | **Yes** |
| 5 | Will the door's lock let the datacenter in? | **No. This is the whole problem.** |

The lock is an AWS **security group** — a list of which addresses may connect. It currently
says *"only 10.16.x.x"*, which is the AWS network. The datacenter's `10.10.82.x` is not on
the list, so the connection is dropped with no error message. From the application's side it
looks like the database is simply not responding.

## What needs to happen

**One change, two confirmations, then a test.**

| # | What | Who | Status |
|---|---|---|---|
| 1 | Confirm the exact on-prem address range the connection will come from | platform | in progress |
| 2 | Find who owns the security group — its name says it was created by Terraform, so it should be changed in code rather than by hand | platform | in progress |
| 3 | Add the on-prem range to the security group, ports 1024-1026 | network / cloud team | **the actual fix** |
| 4 | Test a connection from an on-prem cluster and confirm it succeeds | platform | after 3 |

**The change itself, precisely:**

```
Security group   sg-0c8f8db29b16a1477
Account          937464026810, region us-east-2
Add inbound      TCP ports 1024-1026, from the on-prem worker address range
```

Ports 1024-1026 look unusual and are correct — that is the port range Atlas uses for a
private connection. **A request written for the usual MongoDB port 27017 would be approved
and would not work.**

## What this is *not*

* **Not a redesign.** Nothing about the application changes.
* **Not a new network.** The link exists and carries traffic today.
* **Not a credential problem.** The certificates are unaffected.
* **Not a reason to pause the onboarding.** The rest of the work — the image, the
  configuration, the deployment — is unblocked and can continue in parallel.

## Why it matters beyond this one application

**Every cloud application moved on-prem will hit this**, because this is how US Xpress
connects to Atlas generally. It is worth answering once, as a standing rule — "here is how
on-prem workloads reach Atlas" — rather than rediscovering it for each application.

There is also a wider lesson for the onboarding process: an address that works perfectly in
one environment can be unreachable from another while every credential, every setting and
every status light is correct. The symptom is a timeout, and a timeout looks like a firewall
fault rather than an architectural one. **Checking an application's database addresses before
anything else should be part of every intake.**

## If the answer had been different

For completeness, since it was a live possibility until we traced the path: had no link
existed, the alternative was to switch this application to Atlas's **public** address and add
the on-prem site to the database's own allow-list. That remains available as a fallback —
MongoDB keeps both addresses working at the same time unless the account explicitly turns
public access off — but it sends database traffic over the internet, and it is not needed
here.

## The detail behind this

* Technical trace and sources: `RESEARCH-atlas-from-onprem-2026-10-20.md`
* The application's full dependency list: `DEPENDENCY-MATRIX-pricing-rfp-handler-2026-10-20.md`

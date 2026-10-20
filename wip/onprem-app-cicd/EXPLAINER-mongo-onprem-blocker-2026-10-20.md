# Why the pricing app can't reach its database from on-prem — and what fixes it

**2026-10-20.** Written for anyone who needs to act on this: the application team, the
network team, and whoever signs off the change. No prior context needed.

**Shareable page with diagrams:** https://claude.ai/artifact/1R9Qbe1K5ex9jnZg7u3Hxc
(private until shared from its own Share menu).

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

## The two pictures

**Today, in production.** The application and the database's entrance are both inside the
same AWS network, so the firewall on that entrance already permits the connection.

```
  pricing-rfp-handler pod        Atlas private endpoint        MongoDB Atlas
  10.16.x.x  (in AWS)            10.16.6.113                   (managed service)
        |                               |                             |
        |--- TCP 1024-1026 ------------>|                             |
        |                               |--- AWS PrivateLink -------->|
        |                               |                             |
        \___ firewall on the endpoint: allows 10.16.0.0/20 ___/
             the app is already inside that range, so it passes

  Both ends sit in the same AWS network. Nothing crosses a boundary.
```

**After the move.** Same endpoint, longer path. Every hop between the datacenter and that
AWS network is already routed; only the firewall refuses.

```
  pricing-rfp-handler pod     VPN + transit      Atlas private endpoint     MongoDB
  on Kubernetes, on-prem      gateway            10.16.6.113                Atlas
  leaves as 10.10.82.x
        |                          |                       |                   |
        |--- already routed ------>|--- already routed --->|                   |
        |                          |                       |                   |
        |                          |      firewall on the endpoint:            |
        |                          |      blocks 10.10.82.0/24   <-- X         |
        |                          |      THE ONLY HOP THAT REFUSES            |
        |                          |                       |--- PrivateLink -->|

  The refusal is silent. The application just sees a timeout, which reads like a
  network fault rather than a permission one.
```

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
| 1 | Confirm the on-prem address range | platform | ✅ **10.10.82.0/24** — all three on-prem clusters' machines sit in it |
| 2 | Find who owns the security group | platform | ✅ **an Octopus project called `mongodb`**, space `USXpress`, group `enterprise` — not the platform team's code |
| 3 | Add the on-prem range to the security group, ports 1024-1026 | **the owner of that Octopus project** | **the actual fix** |
| 4 | Test a connection from an on-prem cluster | platform | after 3 |

**The change itself, precisely:**

```
Security group   sg-0c8f8db29b16a1477   ("mongodb-interface-endpoint")
Account          937464026810, region us-east-2
Add inbound      TCP ports 1024-1026, source 10.10.82.0/24
Reason           on-prem Kubernetes clusters reaching MongoDB Atlas
```

**Who to ask.** The security group's tags name its owner: Octopus project **`mongodb`**,
space **`USXpress`**, project group **`enterprise`**, environment **`production`**. So this
is not a console edit and not ours to make — it is a code change in that project, raised with
whoever owns it.

⚠️ **Two things to insist on when it is deployed.**

1. The group's own description reads *"open within VPC"*. Admitting an outside network is a
   deliberate change to its security posture, so it needs the owner's agreement rather than a
   mechanical edit.
2. **An Octopus deployment going green does not mean the change was applied.** These projects
   print the plan and skip the apply unless a flag is set. Ask for the task log and confirm it
   contains `Apply complete!` before testing — otherwise a successful-looking deployment and a
   failed connection will send everyone back to the network.

**One assumption, which the test in step 4 settles.** On-prem pods are expected to leave the
cluster carrying their machine's address (10.10.82.x) rather than their internal pod address
(10.244.x.x). That is the normal behaviour and is why the rule names the machine range. If the
test still fails after the rule lands, this is the first thing to re-check.

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

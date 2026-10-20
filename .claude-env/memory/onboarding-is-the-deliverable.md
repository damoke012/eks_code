---
name: onboarding-is-the-deliverable
description: "RisingWave was brought into the environment with no intake and that is the cost being paid now; the pricing app is the prototype for a standard onboarding — form, epic, repo+README, Confluence, example manifests. Idris owns it end to end, no approval gate"
metadata:
  type: project
---

**Two calls, 2026-10-20.** Idris to the app team: *"we did a mistake where we onboarded
RisingWave where we didn't have all these questions that have been asked … we just went
straight to onboarding. We don't want every app to just go straight to onboarding."* Doke to
the platform team: *"this should be our prototype — our test case — for onboarding as a
platform, most of which we didn't do with Tim. We just brought him into the environment. Going
forward, any application that wants to onboard on-prem has to follow this procedure."*

So **every onboarding engagement has two deliverables**: the app, and the reusable path. The
second is the one that gets dropped under pressure.

**The artifacts Doke named**, which are the product:

* an **epic** for the engagement, and a **discovery form** — *"whatever you have in a form
  right now is totally fine"*; start with discovery, not with a cluster;
* an **architecture diagram separating platform from application**;
* a **repo for their work with a README**: what the engagement is, what is application, what
  is infrastructure, what the onboarding process is;
* a Confluence page for the engagement **and one for onboarding in general**;
* **example files for everything the app team must produce** — pod, deployment, replica set,
  how Helm is used, the values file — so the next team gets a template instead of a meeting;
* a phase walkthrough presented to the team.

**Ownership, stated explicitly:** Idris runs the pricing-app engagement with Shrikant
directly and *"doesn't need anybody's approval to do anything on this."* Expect pushback; pull
the team in when an opinion is wanted. Steve: *"it's never too early to standardize."*

**How to apply.** When an app arrives, the first move is the form, not the namespace. And
when writing anything for the onboarding path, write it for the **next** app — the one nobody
has met — not for the one in the room.

Related: [[onprem-app-cicd]], [[secret-and-owner-are-two-axes]],
[[expiring-config-is-platform-owned-iac]], [[delivery-is-a-relay-of-nine-gates]].

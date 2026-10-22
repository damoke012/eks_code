---
name: expiring-config-is-platform-owned-iac
description: "The ownership rule Doke states in every engagement: the app artifact is identical across environments; anything that expires, is short-lived, or is a managed service is abstracted away from the app, owned by the platform, and created as IaC — and config never goes into the image"
metadata:
  type: feedback
---

Said twice on 2026-10-20, to two different audiences, in almost the same words.

To the app team: *"you would be responsible for your application. Application should be an
artifact that is the same across all environments. The differences will be the environmental
variables — and anything that is sensitive and does expire comes to us. We abstract that away
from you and we manage that for you."*

To the platform team, about the API gateway work: *"anything that is going to be expiring,
things that should be abstracted away from the application itself, those should live within
the platform processes, and those should probably be created as infrastructure as code …
anything else that expires or is short-lived, or if it's an AWS service, we are the ones
orchestrating how that is created and managed."*

**Four rules fall out of it:**

1. **One artifact, every environment.** If the image differs per environment, something that
   should have been a variable was baked in.
2. **Expiry is the test for platform ownership** — not sensitivity alone. A rotating token is
   ours even when the app team could technically hold it.
3. **A managed service is platform-orchestrated**, by agreement with the app team, not
   unilaterally.
4. **Configuration never goes into the image.** Named as one of the specific disagreements
   with Tim.

**How to apply.** When an ownership question comes up, ask *does it expire* and *is it a
service we orchestrate* before asking *is it secret*. Then cross it with secret-ness —
[[secret-and-owner-are-two-axes]] — because the two axes are independent and a one-axis split
always strands keys. And remember the counterpart Doke states just as firmly: app teams **do
not own CI/CD**, and must not be able to edit platform variables because the app happens to
be theirs.

⚠️ The honest part: *"I don't want us to overstep, but we might need to ask more questions to
identify what should be purely handled by the platform versus what should be a total
application call."* The rule decides the default; the app developer still **approves** the
classification of their own app's variables.

## 2026-10-20 — the operational form of the test: who can fix it

"Does it expire" is the first question, not the whole test, and it leaves real keys undecided
(it left 11 of the pricing app's 70 unresolved). The sharper criterion is **who can act when
the value is wrong**:

> If it breaks and the app team cannot resolve it without us, it is platform. If we would have
> to ask them what the right value is, it is application.

Four questions, first answer wins:

1. **Does it expire or rotate?** → platform. They cannot rotate a Confluent key or reissue a
   certificate.
2. **Is it a coordinate of something we run or orchestrate?** → platform.
3. **Does a wrong value break the same way for every app on the cluster?** → platform.
4. **Does changing it change application behaviour a developer decides?** → application.

None of them answering means it is **not a classification problem but an unmade decision** —
record it as undecided with a named owner instead of guessing.

**The finding worth keeping:** applied to the pricing app's SQL configuration, the test
**splits one logical thing in two**. `UsXpressSqlConfiguration__{Bmd,Psa}__Password` is
platform — a DBA rotates it and the app team cannot repair the secret afterwards — while
`__Server`, `__Database` and `__UserId` are application, because they choose which database
and user and we only have to make it reachable.

So **a credential and its coordinates usually land on opposite sides of the line.** A rule
that keeps a connection's parts together will put the password in the app team's values file.

Related: [[secret-and-owner-are-two-axes]] (the second, independent axis),
[[envfrom-hides-the-inventory]] (where the keys actually are).

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

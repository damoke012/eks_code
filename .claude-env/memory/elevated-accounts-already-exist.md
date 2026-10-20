---
name: elevated-accounts-already-exist
description: "Every platform team member already has an unused elevated AD account (<name>_elevated / _ELEV, beside the _admin ones); admin-level logins to AWS/Azure are supposed to use it. Chris on the cyber team runs onboarding"
metadata:
  type: project
---

**Steve, 2026-10-20 platform review.** The server and infrastructure teams' practice is that
any login with **admin-like rights** — AWS, Azure, anywhere — uses a **separate elevated
account**, not the everyday one. Those accounts **have already been created for everyone on
this team** and have been sitting unused: *"it's probably going to be whatever your normal
account name is with an underscore elevated or ELEV"*, alongside the `_admin` accounts
visible in Active Directory.

**Onboarding is run by Chris on the cyber team.** Mark picked it up on the call; Steve called
it explicitly **not urgent** — a security-maturity step, not a response to anything.

**How to apply.** This is the answer to "I should be AWS admin": the account exists, the
onboarding does not. Ask Chris (via Mark or Steve) to onboard the elevated account rather
than asking for rights on the normal one — a privilege request on a daily-driver account is
the thing this practice exists to stop.

Related: [[eks-human-access-model]], [[onprem-human-access-model]],
[[identity-names-do-not-cross-systems]].

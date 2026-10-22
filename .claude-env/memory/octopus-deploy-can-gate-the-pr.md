---
name: octopus-deploy-can-gate-the-pr
description: "In ix-kafka-topics-users the Octopus DEV deploy is a required check that runs from the branch BEFORE merge — the merge→deploy order I assumed is backwards there, and the branch release is the thing that gets deployed"
metadata:
  type: project
---

**2026-10-09, `variant-inc/ix-kafka-topics-users` #303.** I told two people, including Tim,
that the sequence was *merge, then Octopus deploys per environment*. Jeff Shaw corrected it
in passing:

> "Approved. I also started the deploy to dev since that gatekeeps the pull request.
> It's ready for you to close it now."

**The dev deploy runs from the BRANCH and is a required check on the PR.** Merge comes after.
That fits what the repo already showed and I misread: `octo.yml` triggers on `branches: '**'`
and pushes a release to Octopus on every branch push — so a release exists per branch, and
deploying it to dev is what satisfies the gate.

**How to apply.** Before describing a repo's promotion order, read what its PR checks
actually require rather than assuming merge-then-deploy. A deploy that *precedes* the merge
changes two things: the branch release is the artifact that lands, and a stale branch means
a stale deploy — the September release from this same branch was never deployed and sat
unnoticed for 27 days because nobody checked whether creating a release had deployed one
([[octopus-green-but-no-apply]]).

**Still true and unchanged:** merging alone creates nothing in Confluent, and **each
environment is a separate deploy**. Jeff deployed dev. QA is its own deployment of the same
module with its own service account ([[declared-grant-is-not-the-literal-acl]]), so QA's
grant does not exist until someone deploys it there.

Approvals came from `jenni-ray` and `jshaw-usx`; CODEOWNERS on `users/` is
`@variant-inc/engineering-leadership`.

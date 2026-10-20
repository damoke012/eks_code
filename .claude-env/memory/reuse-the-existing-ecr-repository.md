---
name: reuse-the-existing-ecr-repository
description: "On-prem pulls the app's EXISTING ECR repository — the app's GitHub Actions build already pushes there and those repos carry retention policies; a second push doubles storage and splits provenance. Decided by the app team 2026-10-20"
metadata:
  type: project
---

**2026-10-20, pricing-app onboarding call.** The platform proposed building and pushing an
image to ECR for on-prem. Andres and Shrikant pushed back: the app's **existing GitHub
Actions build already pushes to ECR and Octopus pulls from there**, and *"the current ECR
repositories already have retention policies on them so they don't get too big. So we should
just be able to pull that existing one instead of having to push it to a different ECR."*
Accepted on the call.

**So the on-prem image source is the repository the cloud pipeline already fills.** One build,
one digest, one provenance chain, retention already solved. GitHub is common to both paths, so
that is where the build belongs — Shrikant: *"since Git is common to both, you may as well do
it there."*

**How to apply.** Before designing a build for an onboarding app, find out what already
pushes an image and where. The platform needs exactly one thing from an app repo: an image in
ECR ([[two-orgs-join-at-ecr-not-github]]). If one is already there, the build question is
closed and only the **pull** question remains.

⚠️ **This moves, not removes, the policy question.** [[ecr-repo-policy-is-per-repository]] is
about a *new* repo having no policy. Reusing an existing repo means checking whether **that**
repo's policy admits the on-prem account — and it was written for a cloud consumer in the same
account, so it very likely does not. Read the existing repo's policy before promising a pull
works; the failure is a 403 on the manifest HEAD and reads as a credential problem.

⚠️ Measured reality for RisingWave: the shared registry is **064859874041 / us-east-2**
(Infrastructure-Common), not a per-environment account — check the app's actual repository ARN
rather than assuming the per-env pattern.

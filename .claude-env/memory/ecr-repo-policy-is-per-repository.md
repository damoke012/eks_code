---
name: ecr-repo-policy-is-per-repository
description: "A new ECR repository has NO repository policy, so a cross-account on-prem pull 403s at the manifest HEAD; etl-pipeline works only because it carries OnPremClustersPullOnly"
metadata:
  node_type: memory
  type: project
---

**2026-10-09.** op-dev could not pull `064859874041…/risingwave/poc-pipeline@sha256:ac2b1e95`.
`ImagePullBackOff`, and the event's real message was
`unexpected status from HEAD request … 403 Forbidden`.

**Cause: a repository policy is per repository and a new repo has none.**

    risingwave/etl-pipeline  -> Sid OnPremClustersPullOnly, Principal = the three
                                on-prem account roots (700736442855, 527101283767,
                                937464026810), Action = ecr:GetDownloadUrlForLayer,
                                BatchGetImage, BatchCheckLayerAvailability
    risingwave/poc-pipeline  -> RepositoryPolicyNotFoundException

Fixed with `aws ecr set-repository-policy --profile infra-common` granting dev's account
only (nothing in QA/prod consumes that repo). ⚠️ **Set by CLI, so it is drift** — it must be
imported into Terraform beside the three hand-made untagged roles, or a later apply removes
it and dev breaks with no obvious cause. See [[two-projects-one-resource]].

## The hypothesis that was wrong, and why it was tempting

`ecr-pull-secret` in `app-risingwave` was created **2026-08-18** and an ECR auth token lives
12 hours, so "the credential is seven weeks dead and every prior pull was a containerd cache
hit" looked compelling. It is false: `cronjob/ecr-credentials-sync` in namespace
`ecr-credentials` runs `0 */6 * * *`. **A Secret's `creationTimestamp` says nothing about
when its DATA was last written** — the controller updates data in place. Check for the
refresher before theorising about expiry.

## Discriminating ErrImagePull

Three causes, one symptom, different fixes — the event message is the only separator:

| Message | Cause |
|---|---|
| `403 Forbidden` on the manifest HEAD | repository policy (this one) |
| `not authorized to perform: ecr:BatchGetImage` | the pulling principal's own IAM |
| `no basic auth credentials` | the pull secret / credential helper |
| `manifest unknown` | the digest is not in that repository |

Confirm the image really exists first — it costs one call and retires the last row:
`aws ecr describe-images --repository-name <r> --image-ids imageDigest=<d>`.

Related: [[ecr-shared-registry-posture]], [[eso-writes-partial-secrets]].

## 2026-10-20 — which repository the question lands on changed

Decided on the pricing-app onboarding call: on-prem pulls the app's **existing** ECR
repository rather than a new one ([[reuse-the-existing-ecr-repository]]). So the policy
question moves instead of disappearing — an existing repo **has** a policy, written for a
cloud consumer in the same account, which is very likely not the on-prem account. Read that
repo's policy before promising the pull works; the failure is still a 403 on the manifest
HEAD and still reads as a credential problem.

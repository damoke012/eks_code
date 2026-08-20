# Shared ECR registry 064859874041 — policy review (INFRA-1643)

Swept 2026-08-20 with `scripts/audit-ecr-policies.sh --profile infra-common`, both
`us-east-2` and `us-east-1`. **Counts pending the `--summary` run; the findings below do not
depend on them.**

## What the ticket assumed, and what is actually true

INFRA-1643 was filed off one observation: `lazy/api` grants `PutImage`,
`InitiateLayerUpload`, `UploadLayerPart` and `CompleteLayerUpload` to every principal in org
`o-yza5l1xhrc`. I recorded that as a repository to avoid modelling new policies on.

**That was mis-scoped.** `lazy/api` is not an outlier — it is the registry's default. Of the
~400 repositories in `us-east-2`, every one carries the same org-wide write grant except two.
The finding is not "one repo is loose"; it is "the shared registry has no meaningful write
boundary between accounts".

## Findings

**F1 — org-wide write is the default (the headline).**
Any principal in any account in `o-yza5l1xhrc` can push over any tag in any repository. There
is no per-team, per-account or per-pipeline separation. A compromised or simply careless
principal anywhere in the organisation can replace the contents of any image the fleet runs.

**F2 — tags are mutable almost everywhere.**
Only a handful of repositories are `IMMUTABLE`. Combined with F1 this is the part that
matters: a tag can be repointed at different bytes with no deletion, no error and no trace in
the consuming cluster. `:latest`-style consumption anywhere in the fleet inherits this.

**F3 — the on-prem clusters are insulated, by accident of this week's work.**
`require-image-digest` is `Enforce` on the op-qa app namespaces as of 2026-08-20
(INFRA-1640), and the on-prem delivery path promotes by digest, so a repointed tag cannot
reach those workloads. **The EKS fleet has no equivalent control that I have verified**, and
that is where most of these ~400 repositories are actually consumed. The exposure is real and
it sits on the cloud side.

**F4 — `usxpress/playright-base` has no repository policy at all.**
Unreadable from every other account, silently — the INFRA-1633 failure shape, where the
symptom points at the pull secret. Note `usxpress/playwright-base` and
`feature/usxpress/playwright-base` also exist: the policy-less one is a typo'd repository
nobody ever wired up. Almost certainly dead, worth deleting rather than fixing.

**F5 — image scanning is off on most repositories.**
`scanOnPush` is `False` for the large majority. Not a boundary failure, but it means F1's
consequence would not be detected by the registry either.

**F6 — nothing manages any of this as code.**
`aws_ecr_repository` appears exactly once in the whole variant-inc org, in an interview
sandbox (established 2026-08-20 for INFRA-1633). Every one of these ~400 policies was applied
by hand or by a pipeline nobody has identified. There is no place to make a fleet-wide change,
which is why F1 cannot be remediated as a single PR.

## Proven

* `risingwave/etl-pipeline` is the only read-scoped repository in the registry: read to three
  named accounts, `IMMUTABLE`, `scanOnPush` true, 2026-08-20. It is the one created today.
* Both `docker-hub/*` mirrors and first-party application images carry the same org-wide write
  grant — the mirror namespace is not treated differently from application code.

## Tested and killed

* **Fixing this under INFRA-1643.** Rejected: the ticket asks for a review, and remediation is
  ~400 policy changes across two regions with no IaC to change them in. Narrowing the grants
  will break any build that currently relies on the org-wide write, and nobody has enumerated
  which builds those are. It needs its own ticket and an owner on the cloud side.

## Traps

1. **One repository's policy is not the registry's posture.** Reasoning from `lazy/api` alone
   produced a finding that was true and badly scoped. Enumerate before characterising.
2. **`describe-registry` does not answer "who can push".** It returns replication
   configuration. `get-registry-policy` is the call for the permissions policy.
3. **A digest pin is the only defence against F2 that survives a mutable tag.** It is the
   reason on-prem is safe here, and it was put in place for unrelated reasons.

# Shared ECR registry 064859874041 — policy review (INFRA-1643)

Swept 2026-08-20 with `scripts/audit-ecr-policies.sh --profile infra-common`, both
`us-east-2` and `us-east-1`, 2026-08-20 21:00Z.

| | us-east-2 | us-east-1 | total |
|---|---|---|---|
| repositories | 497 | 20 | **517** |
| write granted to the whole org `o-yza5l1xhrc` | 495 | 20 | **515 — 99.6%** |
| write granted to named accounts | 0 | 0 | 0 |
| read-only, correctly scoped | 1 | 0 | **1** |
| no repository policy at all | 1 | 0 | **1** |
| `IMMUTABLE` tags | 5 | 2 | **7 — 1.4%** |
| `scanOnPush` enabled | 51 | 16 | **67 — 13%** |

**There is no registry-level permissions policy** (`get-registry-policy` returns empty in both
regions). Authorisation is entirely per-repository, across all 517.

## What the ticket assumed, and what is actually true

INFRA-1643 was filed off one observation: `lazy/api` grants `PutImage`,
`InitiateLayerUpload`, `UploadLayerPart` and `CompleteLayerUpload` to every principal in org
`o-yza5l1xhrc`. I recorded that as a repository to avoid modelling new policies on.

**That was mis-scoped.** `lazy/api` is not an outlier — it is the registry's default. Of the
517 repositories across both regions, 515 carry the same org-wide write grant. Exactly one is
scoped read-only, and one has no policy at all.
The finding is not "one repo is loose"; it is "the shared registry has no meaningful write
boundary between accounts".

## Findings

**F1 — org-wide write is the default (the headline).**
Any principal in any account in `o-yza5l1xhrc` can push over any tag in any repository. There
is no per-team, per-account or per-pipeline separation. A compromised or simply careless
principal anywhere in the organisation can replace the contents of any image the fleet runs.

**F2 — tags are mutable almost everywhere.**
7 repositories of 517 are `IMMUTABLE` — 1.4%. Combined with F1 this is the part that
matters: a tag can be repointed at different bytes with no deletion, no error and no trace in
the consuming cluster. `:latest`-style consumption anywhere in the fleet inherits this.

**F3 — the on-prem clusters are insulated, by accident of this week's work.**
`require-image-digest` is `Enforce` on the op-qa app namespaces as of 2026-08-20
(INFRA-1640), and the on-prem delivery path promotes by digest, so a repointed tag cannot
reach those workloads. **The EKS fleet has no equivalent control that I have verified**, and
that is where most of these 517 repositories are actually consumed. The exposure is real and
it sits on the cloud side.

**F4 — `usxpress/playright-base` has no repository policy at all.**
Unreadable from every other account, silently — the INFRA-1633 failure shape, where the
symptom points at the pull secret. Note `usxpress/playwright-base` and
`feature/usxpress/playwright-base` also exist: the policy-less one is a typo'd repository
nobody ever wired up. Almost certainly dead, worth deleting rather than fixing.

**F5 — image scanning is off on most repositories.**
`scanOnPush` is enabled on 67 of 517 — 13%. Not a boundary failure, but it means F1's
consequence would not be detected by the registry either.

**F6 — nothing manages any of this as code.**
`aws_ecr_repository` appears exactly once in the whole variant-inc org, in an interview
sandbox (established 2026-08-20 for INFRA-1633). Every one of these 517 policies was applied
by hand or by a pipeline nobody has identified. There is no place to make a fleet-wide change,
which is why F1 cannot be remediated as a single PR.

## Proven

* `risingwave/etl-pipeline` is the only read-scoped repository in **either region**: read to three
  named accounts, `IMMUTABLE`, `scanOnPush` true, 2026-08-20. It is the one created today.
* Both `docker-hub/*` mirrors and first-party application images carry the same org-wide write
  grant — the mirror namespace is not treated differently from application code.

## Tested and killed

* **Fixing this under INFRA-1643.** Rejected: the ticket asks for a review, and remediation is
  515 policy changes across two regions with no IaC to change them in. Narrowing the grants
  will break any build that currently relies on the org-wide write, and nobody has enumerated
  which builds those are. It needs its own ticket and an owner on the cloud side.

## Traps

1. **One repository's policy is not the registry's posture.** Reasoning from `lazy/api` alone
   produced a finding that was true and badly scoped. Enumerate before characterising.
2. **`describe-registry` does not answer "who can push".** It returns replication
   configuration. `get-registry-policy` is the call for the permissions policy.
3. **A digest pin is the only defence against F2 that survives a mutable tag.** It is the
   reason on-prem is safe here, and it was put in place for unrelated reasons.

## Where the ECR IaC lives — searched 2026-08-26, and the answer looks like "nowhere"

INFRA-1651 and INFRA-1670 both wait on identifying which repository owns account
064859874041. Searched the whole `variant-inc` org:

```
gh search code --owner variant-inc "064859874041"      -> 202 results
gh search code --owner variant-inc "aws_ecr_repository" ->   1 result
```

**All 202 hits are consumers** — Dockerfiles with `FROM 064859874041.dkr.ecr…`, READMEs,
helm `oci://` references. The single `aws_ecr_repository` hit is
`interview-platform-eng-sandbox/exercises/04-tf-state-split/monolith.tf`, which is an
interview exercise.

**517 repositories exist in that registry and no Terraform in the organisation describes
any of them.** The strong inference is that they are created imperatively — most likely on
demand by the shared build actions (`actions-dotnet`, `actions-python`, `actions-go`,
`actions-nodejs`, all of which document the registry in their READMEs). Next search:
`create-repository` and the actions' `action.yml`.

### Ruled out: `iac-tf-manual-runs`

It looked like the owner because `apps/common/ecr_endpoint/README.md` names
`arn:aws:iam::064859874041:role/github-iac-ecr-vpc-endpoint-role`. Reading the module
settles it: the inline policy is **entirely `ec2:`** — `CreateVpc`, `CreateVpcEndpoint`,
security groups, route tables. **Not one `ecr:` action.** It provisions the *VPC endpoint*
used to reach ECR privately, not ECR repositories.

Its trust policy points onward — `sub: repo:variant-inc/iac-tf-common-endpoints:*` — so
`iac-tf-manual-runs` is the manual bootstrap that created a role for
`iac-tf-common-endpoints` to use. Still endpoints. Still not repositories.

**What this means for INFRA-1670.** If ECR repositories are created imperatively by the
shared actions, then `wip/onprem-app-cicd/terraform/ecr-app-repos.tf` is a *deliberate
deviation from the house pattern*, not an adoption of it — and that is a decision to make
openly rather than discover later. The on-prem case is different in a way that may justify
it: these repositories need a **cross-account pull policy** for three cluster accounts,
which a build action creating a repository on demand will not add, and whose absence is
invisible until the first pull.

### Two findings that are not about ECR

* **`terraform.tfstate` is committed to git** at `apps/common/ecr_endpoint/terraform.tfstate`
  (and `.backup`), readable through code search. This module's state holds account IDs, role
  ARNs, full inline policies and the assumed-role identity of the engineer who ran it —
  nothing secret here, but state in git is a pattern, and Terraform state routinely contains
  secrets in modules that manage them. Worth a ticket against whoever owns that repo.
* **Account `108141096600` holds Terraform state**, via
  `arn:aws:iam::108141096600:role/github-iac-tf-state-role`. Not previously in our account
  map: dev 700736442855, QA 527101283767, prod 937464026810, ECR 064859874041, network
  155768531003, org management 660075424663.

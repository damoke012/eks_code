Round 1 — `39286d0`, full diff read. **Blocking, on two things that compound.**

The underlying problem is real and worth fixing: a `workflow_dispatch` job that references a
GitHub Environment sends `environment:<name>` as the `sub` claim, and a policy pinned to
`ref:refs/heads/master` rejects it. That diagnosis is correct. It is the size of the fix I
cannot sign off.

## 1. (BLOCKER) `repo:variant-inc/risingwave-pipeline:*` admits `pull_request`

    - "…:sub" = "repo:variant-inc/risingwave-pipeline:ref:refs/heads/master"
    + "…:sub" = "repo:variant-inc/risingwave-pipeline:*"

`sub` takes several shapes and the wildcard matches all of them — every branch, every tag,
every environment, and **`repo:variant-inc/risingwave-pipeline:pull_request`**. A workflow
triggered by a PR from a branch in that repo runs with whatever permissions it requests, so
anyone who can open a PR there can mint a token that assumes this role. Given the org grants
push on 515 of 517 ECR repositories with no registry policy (INFRA-1655), "anyone who can
open a PR" is not a small set.

`StringLike` takes a **list**. That covers your dispatch case without admitting PRs:

```hcl
"token.actions.githubusercontent.com:sub" = [
  "repo:variant-inc/risingwave-pipeline:ref:refs/heads/master",
  "repo:variant-inc/risingwave-pipeline:environment:dev",
  "repo:variant-inc/risingwave-pipeline:environment:qa",
  "repo:variant-inc/risingwave-pipeline:environment:prod",
]
```

Worth saying plainly: the comment this PR deletes already made the argument.

> Subject: ONLY variant-inc/risingwave-pipeline master branch. **Blocks PRs from forks +
> other branches.** If we need to allow feature-branch testing, use workflow_dispatch with
> explicit role override **rather than broadening this scope.**

## 2. (BLOCKER) The role now reads `/risingwave/*` — Tim's production path

    Resource = [
    + "…:secret:${var.cluster_name}/risingwave/*",
      "…:secret:${var.cluster_name}/risingwave-2/*"
    ]

The deleted comment is explicit about why these were apart:

> Companion to `gha-risingwave-poc-secrets-role.tf` (**Tim's prod equivalent pointing at
> /risingwave/***). **Kept as separate roles so prod and CICD-env credentials are
> independently rotatable + auditable.**
> SM ARN: ONLY `op-usxpress-dev/risingwave-2/*` … **Does NOT include /risingwave/ (Tim's
> prod).**

Separately each change is arguable. Together they are the problem: a **wildcard-trusted
role** that can read **production RisingWave credentials**. Any PR in that repo becomes a
read of prod secrets, and the separation that made prod credentials independently rotatable
is gone.

If the pipeline genuinely needs `/risingwave/*` on QA and prod, I would rather that were its
own role with its own narrow subject, keeping the property the original design was after.

## 3. (advisory) `risingwave-2` is dev-only

`${var.cluster_name}/risingwave-2/*` is granted in every environment, but `risingwave-2` is
dev-only and never promoted — QA and prod only ever have `risingwave`. Dead scope today, and
a live grant the moment someone creates that path in prod. Consider gating it on
`var.cluster_name == "op-usxpress-dev"`.

## 4. (advisory) `data.aws_caller_identity.current.account_id` follows the caller

Replacing the hardcoded `700736442855` is the right direction — the module should be
parameterised. The trade is that a wrong-account apply now succeeds quietly instead of
failing loudly. Release 0.5.6 died in production last week reading QA's state bucket, so
this is not hypothetical here. A `precondition` asserting the resolved account matches an
expected per-env variable keeps the parameterisation and restores the loud failure.

## Cleared ✅

- Diagnosis of the `environment:` sub claim — correct, and the reason the old policy failed.
- Dropping the hardcoded account ID and path in favour of `var.cluster_name` — right call.
- Your test plan is the right shape: plan on dev, confirm only trust-policy and ARN changes,
  then re-run the dispatch against QA and check `sts get-caller-identity`.

## To unblock

Narrow the subject to the explicit list in §1, and either drop `/risingwave/*` or split it
into its own role per §2. With those two, I will approve the same day — the rest of this is
a genuine improvement over what it replaces.

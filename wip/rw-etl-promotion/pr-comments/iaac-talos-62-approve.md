Round 2 — `3441ae9`, full diff read. **Approving.**

**Both blockers cleared, verified in the diff rather than from the commit title.**

1. **Subject is an explicit allowlist.** `master` plus `environment:dev|qa|prod`, no
   wildcard anywhere, so `repo:…:pull_request` no longer matches. This solves the
   `workflow_dispatch` case you diagnosed without admitting PR tokens.
2. **`/risingwave/*` is gone.** The policy now names `${cluster_name}/risingwave-2/*` and
   nothing else, so Tim's production path stays with Tim's role and the two remain
   independently rotatable.

**And you improved on the ask.** You did not just restore the scope comment — you rewrote
it for the new shape and added `This role MUST NOT include /risingwave/*.` That converts
the reasoning I had to quote back from a deleted comment into a standing instruction the
next person reads before they widen it. That is the better fix.

**Two advisories, neither blocking, both fine as follow-ups**

- `${cluster_name}/risingwave-2/*` is granted in every environment, but `risingwave-2` is
  dev-only and never promoted. It is dead scope on QA and prod today rather than a live
  grant, so it is much less pressing now that it is the only resource — worth gating on
  `var.cluster_name` when you are next in this file.
- `data.aws_caller_identity.current` means a wrong-account apply succeeds quietly rather
  than failing loudly. A `precondition` asserting the resolved account matches an expected
  per-env variable keeps the parameterisation and restores the loud failure.

**One question, not a blocker.** The policy has a second `Statement` block that neither
diff shows, because this PR does not touch it. I have therefore never read it, and I am not
going to imply I reviewed the whole role. Approving this on the change it makes; if that
statement grants anything broad, it is worth a separate look on its own merits rather than
holding up a fix that strictly narrows the role.

**Three things about the Octopus run, since that is the next step**

1. **A green deploy is not an apply.** `iaac-talos` deploys print the plan, skip the apply
   and report Success — `TfApply` is false everywhere but production. Your dev run will
   show the trust-policy and ARN diff, which is what your test plan wants, but the role
   will not change until apply is armed. The proof it applied is the `terraform_outputs.yml`
   artifact on the task, written only on the apply branch. Do not take the green tick.
2. **A release freezes its variables at creation.** Correcting a project variable after
   cutting the release does not reach that release. This is what bit 0.5.6.
3. **Check the account the plan resolves to** before promoting, for the reason in the
   second advisory above. Each environment has its own state bucket and 0.5.6 died in
   production reading QA's.

**And a heads-up that is nothing to do with your change.** Test plan step 2 — re-running
`secret.yaml` against QA — will fail regardless right now. QA's Sync-hook Job has been
unable to start for nine days on the missing `entity-postgres` secret, so the environment
is wedged. Worth knowing before that reads as the OIDC fix not working.

Thanks for turning this round properly.

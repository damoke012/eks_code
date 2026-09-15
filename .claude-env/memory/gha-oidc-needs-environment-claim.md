---
name: gha-oidc-needs-environment-claim
description: "A GHA job's OIDC subject carries environment:<name> only if the job declares environment: — a trust policy written against that claim rejects every job that doesn't"
metadata:
  type: project
---

`risingwave-pipeline`'s `execute` job failed at "Configure AWS via OIDC" with
**"Not authorized to perform sts:AssumeRoleWithWebIdentity"**. The role, the account and the
repo were all correct. The missing piece was one line.

The poc role in dev AND qa trusts only:

    token.actions.githubusercontent.com:sub =
      repo:variant-inc/risingwave-pipeline:environment:dev | :environment:qa | :environment:prod

A job's OIDC subject carries `environment:<name>` **only if the job declares `environment:`**.
`execute` declared none, so its subject was `repo:...:ref:refs/heads/dev` and matched nothing.
Fixed by `environment: ${{ needs.validate.outputs.environment }}` (PR #42). No IAM change.

✅ Proven green on dev 2026-09-15, run 34976661219: OIDC, caller identity, and both Secrets
Manager reads (`op-usxpress-dev/risingwave/{postgres,root}`) all passed.

**Two effects, one cause — the second is silent.** Environment-scoped secrets are also
invisible to a job with no `environment:`. `RISINGWAVE_HOST`, `RISINGWAVE_PORT`,
`POSTGRES_HOST`, `POSTGRES_PORT` live on the `dev` environment, so they were resolving to
**empty strings with no error**. Setting them correctly changed nothing until #42 landed.

**It also explains the run history.** dev's `...-pipeline-secrets` role trusts
`ref:refs/heads/master` and nothing else. That is why the old hardcoded role cleared OIDC on
master pushes and then died one step later at the secret path — and why a push to any other
branch could never have authenticated at all. Three runs, three identical failures, one cause
nobody had read the trust policy for.

**How to apply:** on `sts:AssumeRoleWithWebIdentity` denied, read the trust policy's `sub`
condition BEFORE changing anything — AWS returns the same message for a missing role, an
untrusted repo, and a trusted repo whose claim shape differs. Then check the job actually
emits the claim shape the condition asks for: `environment:` in the job for an
`:environment:` condition, the branch for a `:ref:` condition. And diff against a role that
is known to work rather than reasoning from the failing one alone —
`scripts/rw-compare-oidc-trust.sh` does exactly that, qa first.

Related: [[computed-value-never-consumed]], [[two-gha-roles-one-pipeline-repo]],
[[proxy-is-not-the-property]].

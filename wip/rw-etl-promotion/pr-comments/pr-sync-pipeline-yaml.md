## What

`git checkout origin/master -- .github/workflows/pipeline.yaml`. No hand edits.

## Why

A workflow file runs as it exists **on the branch receiving the push**, so a fix merged to
`master` does nothing for a merge into this branch. This branch has to carry the same file or
the fix is not in effect here.

Brings across, in order:

- the trigger listing `master`, `qa` and `dev` — before this, only `master` was listed, so a
  merge into this branch ran nothing at all
- the role following the namespace, so the job assumes a role that can actually read the secret
  path it is about to request
- `RW_NS` and `ROLE_KIND` as constants (`risingwave` / `poc`) rather than per-environment
  values, since every environment now uses the same namespace and role

## Scope

Identical to `master` after PR #35. Nothing in this PR is specific to this branch, and no
behaviour changes for an environment other than the one this branch deploys.

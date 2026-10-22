---
name: platform-repo-branch-refs-collide
description: iaac-talos-flux-platform has BARE `dev`, `qa` and `prod` branches alongside op-dev/op-qa/op-prod, so any branch named `qa/...` is rejected at push with "directory file conflict" — and the bare names are a standing trap when picking a PR base
metadata:
  type: reference
---

Measured 2026-10-08, `variant-inc/iaac-talos-flux-platform`:

    885aa45a  refs/heads/dev
    c1b8ae6c  refs/heads/prod
    c1b8ae6c  refs/heads/qa      <- same sha as prod

Those sit **alongside** the live cluster branches `op-dev`, `op-qa`, `op-prod`.

## A branch named `qa/anything` cannot be pushed

Git stores refs as files. `refs/heads/qa` is a file, so `refs/heads/qa/rw-console-route`
would need `qa` to be a directory. The push is rejected:

    ! [remote rejected] qa/rw-console-route -> qa/rw-console-route (directory file conflict)

It is a **namespace collision, not a permissions or content problem**, and the message does
not say so. Same for `dev/...` and `prod/...`.

**How to apply:** prefix branches with something that is not an environment name — `dns/`,
`fix/`, `infra-1234/`. `dns/qa-rw-console-route` works where `qa/rw-console-route` cannot.
Recover with `git branch -m <old> <new>` and push again; the commit is untouched.

## The bare names are also a PR-base trap

`qa` and `prod` point at the **same** sha and have not moved with the cluster branches, so
they are stale leftovers. They are one tab-completion away from `op-qa` and `op-prod` when
picking a base, in a repo where the GitHub default is `op-dev`. **Always pass `--base` with
the `op-` prefix explicitly** — `gh pr create --base op-qa`. See
`scripts/lint-pr-base-pinned.sh`, written after a prod change was offered for merge into dev
on 2026-09-03.

Deleting the three bare branches is a cleanup worth a ticket. Confirm first that nothing
references them — a Flux `GitRepository`, an Octopus project or a webhook could be pinned to
`qa` and would stop silently.

Related: [[manifests-copied-across-branches]], [[handing-over-commands]].

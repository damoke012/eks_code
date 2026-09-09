Requesting changes so the state is visible on the PR rather than only in the thread.

Two things to change, both small:

1. **Rebase onto current `master`.** `deploy/overlays/qa/kustomization.yaml` in this branch
   reverts the QA digest from `5108f32…` to `d616242…` (the 19 August image), because the
   branch predates #20. Merging as-is undoes that promotion. Ideally this PR stops touching
   `kustomization.yaml` altogether and leaves the digest to the promotion PRs.
2. **Make an empty `PIPELINE_DIR` exit non-zero.** When the glob matches nothing at all,
   `apply.sh` prints "no .sql or .rw files under …" and exits 0, so the Job reports success
   having applied nothing. A one-character path typo produces a green cutover that did
   nothing. This is the PR that changes `PIPELINE_DIR`.

Not blocking on you, but this cannot land until it is fixed either way: the QA Sync-hook Job
has been unable to start for eight days on the missing `entity-postgres` secret, so nothing
reaches QA — not this, not #23.

Everything else is cleared. `CUTOVER_SCOPE.md` and the `EXCLUDE_RE` are exact — I re-ran the
regex against the tree and it selects precisely the two Brand files.

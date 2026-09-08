Approving. One line, digest only, and the body accurately describes what merging
does.

Two things worth saying out loud before it lands, because this is a bigger jump
than it looks:

**QA is still on `sha256:d616242...`.** Neither open promotion had merged, so
this moves QA forward by everything between the build behind that digest and
`4873de43` — roughly two weeks — in one step, not by a single commit.

**#17 is superseded and being closed.** `310aa151` is an ancestor of `4873de43`,
confirmed by `git merge-base --is-ancestor`, so nothing is lost by closing it.

`PIPELINE_DIR` is untouched here, so QA stays on the smoke payload until #21
decides that separately.

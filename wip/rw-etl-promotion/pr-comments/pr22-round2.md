Round 2 — one correction of mine, and one finding that replaces it.

**My blocker 2 was wrong. Withdrawn.**
I said this PR carries `apply.sh` and both docs. It does not. I read the diff GitHub
displays, which is computed from a merge-base that predates the #21 squash — the effective
diff is what matters:

    git diff --stat origin/master pr-22
    deploy/overlays/prod/endpoints.yaml   |  2 +-
    deploy/overlays/qa/CUTOVER_SCOPE.md   | 79 ++++++++++
    deploy/overlays/qa/endpoints.yaml     |  4 +++-
    deploy/overlays/qa/kustomization.yaml |  2 +-

Four files, 84 lines, overlay only — exactly as you described it. `apply.sh` and the docs
in this branch are byte-identical to merged master (`git diff origin/master pr-22 --
build/apply.sh …` is empty), so there is no revert risk there. My apologies: I measured the
displayed diff instead of the effective one, which is the same mistake I have been
complaining about all week.

**New blocker, in the file I had not read.**

`deploy/overlays/qa/kustomization.yaml` in this branch **reverts the QA image digest**:

    -    digest: sha256:5108f3208b99c2a8b67cd673c6c0f7cb5ece31672349eef58c565765a568f0af
    +    digest: sha256:d6162426d98af2a69e38d09d45a4799178e0a8140abed08d597339796e2ed803

`d616242…` is the **19 August** image. `5108f32…` is what #20 merged today. The branch was
cut before #20 landed, and because it touches that file, merging it puts QA back on the old
image — undoing a promotion, with a green merge behind it. It is the same shape as the
#17-after-#20 ordering trap, arriving through a different door.

A rebase onto current `master` fixes this and the display noise together:

    git fetch origin
    git rebase origin/master cutover/qa-brand-pipeline
    git push --force-with-lease

That should leave three files: `qa/endpoints.yaml`, `qa/CUTOVER_SCOPE.md`, and the
`prod/endpoints.yaml` comment. Note that #23 is now open and promotes `ae5176cb`, built
from the #21 merge — so the digest this overlay should carry is whatever is on `master`
after #23 lands, not one pinned in this branch. Ideally this PR stops touching
`kustomization.yaml` at all and leaves the digest to the promotion PRs.

**Still open from Round 1**

1. **(BLOCKER) The QA Job still cannot start.** `entity-postgres/{username,password}` do
   not exist in QA Secrets Manager, so `etl-pipeline-credentials` has three of five keys
   and the Sync-hook Job has been in `CreateContainerConfigError` for seven days. Nothing
   reaches QA until that Octopus run is through — not this PR, and not #23.
2. **(BLOCKER) A wrong `PIPELINE_DIR` exits 0.** When the glob matches nothing at all,
   `apply.sh` reports success having applied nothing. Tested against a fixture: a
   one-character path typo gives a green Job. This is the PR that changes `PIPELINE_DIR`.
3. **(question) Brand's Kafka credentials.** The live ExternalSecret maps five keys and
   none is a Kafka key, while `CUTOVER_SCOPE.md` requires bootstrap, SASL and three
   schema-registry values. If `100-sources.rw` carries `%KAFKA_…%` tokens, your own
   validation will refuse to connect and name them.

**Cleared and unchanged from Round 1:** the rendered-content hashing, the exit-1 on an
empty selection, and `EXCLUDE_RE` — I re-ran your regex against the tree at `4873de43` and
it selects exactly `Brand/100-sources.rw` and `Brand/200-ingest.rw` out of 24 files.
`CUTOVER_SCOPE.md` is the right artifact and I would like it kept as the pattern for the
next cutover.

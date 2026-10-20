---
name: immutable-tag-blocks-base-image-rebuild
description: "ECR tag immutability + a commit-SHA tag means re-running a build is impossible, so a changed BASE image can never reach an unchanged source commit"
metadata:
  node_type: memory
  type: project
  originSessionId: 47b0e9a0-2e5c-4874-83f1-06d3268ab121
  modified: 2026-10-09T22:21:42.579Z
---

`risingwave/poc-pipeline` (064859874041, profile **infra-common**) is tag-immutable, and
`usxpressinc/risingwave-poc`'s `build-sql-image` tags by **commit SHA**. Measured 2026-10-09:
two `workflow_dispatch` runs on `master` (37997878026, 37998173151) failed at the push step
with `tag invalid: The image tag '1b2e91f8...' already exists … cannot be overwritten because
the tag is immutable`, ~90s after a `publish-applier` run. The build, the scan, the OIDC
assume and the ECR login all passed first — the failure is the last step only.

Two consequences:

1. **Re-running a build for an unchanged commit always fails.** It is not a regression and not
   a permissions problem. `gh workflow run` on an unchanged ref cannot succeed, by design.
2. **A base-image change cannot be rebuilt onto an unchanged commit.** Tim's image is built
   `FROM .../risingwave/sql-applier:latest`. Moving that tag changes what the image *would*
   contain, but the tag the build pushes is derived from source, so there is no path from a new
   base to a new image without a new commit.

   ⚠️ CORRECTED same evening: I first wrote "any commit will do, including an empty one". An
   empty commit is **not** sufficient. `build-sql-image` filters its push trigger on
   `paths: ['pipelines/**', '.github/workflows/build-sql-image.yml']`, and an empty commit
   changes no files, so **no run is created at all** — not a failure, simply nothing, which
   looks identical to a build that has not started yet. What the empty commit *does* achieve is
   moving `master` to a new SHA, which frees the immutable tag. The working sequence is both
   halves: push the commit, then `gh workflow run build-sql-image --ref master`. Touching a real
   file under `pipelines/` would trigger it unaided.

So "merge the applier fix, then republish the applier" is only two thirds of a rollout. The
third part is a commit in the consuming repo, and nothing in either repo says so.

**Proven:** the error text, the step-level conclusions, and that the base image pulled fine
(the local build succeeded) — so a moved `latest` does not break the build, it is simply
ignored.
**Tested and killed:** that tonight's hand-made ECR repository policy on `poc-pipeline` or the
`ecr-push` IAM policy addition caused it. Both were my first two theories; the ECR login
succeeded, which clears both.
**Traps:** `gh run view --log` returned **0 lines and 0 bytes of stderr** for this run —
silently nothing, which reads as an empty log rather than a failure. `gh api
repos/<org>/<repo>/actions/jobs/<id>/logs` returned all 1079 lines. And `--log-failed` printed
nothing at all for the same run, so an empty result from either is NOT MEASURED, never
evidence. Related: [[two-orgs-join-at-ecr-not-github]],
[[ecr-repo-policy-is-per-repository]], [[config-can-outrun-the-image]],
[[delivery-is-a-relay-of-nine-gates]].

⚠️ **CORRECTED 2026-10-12 — the consuming repo pins the applier by DIGEST.** This note
said Tim's image is built `FROM .../risingwave/sql-applier:latest`. The live caller
(`usxpressinc/risingwave-poc/.github/workflows/build-sql-image.yml`) passes
`applier_image: …/risingwave/sql-applier@sha256:0a13bc0de621…`, with its own comment
saying why. The reusable workflow's *default* is still `:latest`, which is what
`iaac-risingwave-cicd#4` fixes — the default, not this caller.

This makes the rollout **simpler**, not harder: moving `latest` reaches nobody, and
publishing a new applier means editing that digest in `build-sql-image.yml`. That file is
inside the workflow's own `paths:` filter, so the edit **self-triggers** a build on a new
commit SHA. No empty commit and no `gh workflow run` are needed — both of which this note
previously prescribed.

⚠️ **A GitHub Actions log is not plain text.** Every line carries a timestamp prefix and
CRLF line endings, so an anchored pattern like `grep -E 'Failed$'` matches nothing in a
43 KB log of a job that plainly failed — three times in a row on 2026-10-16 before I
believed the grep instead of the job. Pipe it through `tr -d '\r'` first, and treat "one
hit in a large failing log" as implausible rather than as a finding.

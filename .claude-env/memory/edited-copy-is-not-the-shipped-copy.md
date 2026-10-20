---
name: edited-copy-is-not-the-shipped-copy
description: "apply.sh lives in TWO repos; two reviewed PRs landed in the copy nothing builds. Before reviewing a change, prove the file is in an image build path."
metadata:
  type: feedback
---

**2026-10-14.** `apply.sh` exists in both `variant-inc/risingwave-pipeline/build/` and
`variant-inc/iaac-risingwave-cicd/build/`. **Only the second is built** (`publish-applier.yml`
→ `risingwave/sql-applier`). PRs #102 and #111 were carefully reviewed, correctly written and
merged into the first — and could never run. Dev reported green on 4-day-old behaviour for
~15 hours. The same EXCLUDE_RE fix had already landed separately in both repos five days
earlier, which was the unread signal.

**Why:** every downstream signal was honest and green. The pin
(`applier_image: …@sha256:…` in the CONSUMING repo's workflow) is good practice and it is also
what makes a stale applier invisible — the image is exactly what it says it is.

**How to apply:**
- Before reviewing or merging a change to a script that ships in an image, run
  `gh search code --owner <org> '<artifact-name>'` and confirm **this** path is what the build
  reads. A `build/` directory is not evidence.
- Before concluding a rebuild will pick up a base-image change, read how the base is
  **referenced**: a moving tag needs a consuming-repo commit ([[immutable-tag-blocks-base-image-rebuild]]);
  a pinned digest needs the **pin bumped** and the commit does nothing on its own.
- Prove it at the destination with an object only the new code creates — here
  `pipeline_applied_history`. Not a green sync, not a Succeeded hook.

Rollout shape for this pair: port → `publish-applier` → bump `applier_image` in
`usxpressinc/risingwave-poc/.github/workflows/build-sql-image.yml` → `build-sql-image` →
`promote` → Argo. Related: [[a-version-declared-twice-will-drift]], [[two-projects-one-resource]],
[[adjacent-step-green-signals]], [[gitops-has-four-stale-layers]].

## 2026-10-15 — the same class, now for workflows, and "disabled" is not "inert"

`variant-inc/risingwave-pipeline` carried **two** promotion workflows. I planned a day's work
repointing `promote-to-qa.yml` — the one whose name matched what I was looking for. It is the
**superseded predecessor**. `promote.yml` (active) already implemented the whole
ECR→dev→QA→prod same-digest chain, with prod left for a human, and said so in its own header.
Nothing needed writing; the fix was `git rm`.

**`gh workflow list --all` is the one command that distinguishes them** — it prints
`disabled_manually` beside `active`. Read it before reading any workflow file.

⚠️ **A disabled workflow holding a `cron` is armed, not dormant.** `promote-to-qa.yml` carried
`*/10 * * * *`, polled the **wrong** ECR repository (`etl-pipeline`, while the values file now
reads `poc-pipeline`), and had **no repository guard** — that check lives only in `promote.yml`.
Re-enabling it would, within ten minutes and with no human involved, write a digest that cannot
exist in the repository QA pulls from.

**How to apply:** when two artefacts could plausibly be the one that runs, the question is never
"which looks right" but "which does the platform invoke" — `gh workflow list --all` for workflows,
the build path for scripts. And before judging a disabled thing harmless, read its triggers.
Related: [[a-version-declared-twice-will-drift]].

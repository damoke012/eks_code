---
name: a-guard-can-measure-the-wrong-thing
description: "A guard that aborts has two possible causes — the thing it watches, or itself; `git status --porcelain` collapses an untracked DIRECTORY to one line, so a file-count guard aborted a correct 8-file add"
metadata:
  type: feedback
---

**2026-10-08, pipeline PR #76.** A pre-commit guard asserted eight new files:

    N=$(git status --porcelain | wc -l)
    [ "$N" = "8" ] || echo "ABORT - expected 8 new files"

The add was correct. `git status --porcelain` **collapses an untracked directory into a
single line** — eight files under a new `deploy/chart/` report as one `?? deploy/chart/`.
N was 1, the guard aborted, nothing committed, and the next step failed with
`No commits between master and feat/etl-helm-chart`, which reads like a branch or upstream
problem and is nothing of the kind.

**Why:** Both symptoms pointed away from the guard. The real defect was in the instrument.

**How to apply.**

1. `--porcelain -uall` enumerates each file. Assert the **shape** as well as the count:
   also count the paths *outside* the directory you meant to touch, and require zero.
2. **Print the measurement beside the threshold** — `files=$N (want 8)`. A guard whose only
   output is ABORT cannot be debugged from the other end of a handover, and costs a round
   trip every time it is wrong.
3. When a guard fires, suspect it **before** suspecting the system. Same family as
   [[proxy-is-not-the-property]] and [[transport-failure-not-a-verdict]]: the check and the
   thing checked are different objects, and a check can be broken in a way that looks
   exactly like a finding.

A guard that cannot fail is not a check — and a guard that fails for its own reasons is
worse, because it also destroys the work it was protecting.

Recorded in the `handing-over-commands` skill as mode 6, together with mode 7: a ~40-line
markdown PR body truncated mid-heredoc and stranded the shell at a `>` prompt, so the next
pasted block was consumed as heredoc content. Quoting a heredoc makes it safe, not short.

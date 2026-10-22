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

**Instance 2026-10-12 — aggregate count cannot see a partially dead pattern.**
`apply.sh` guards its own exclusion with "EXCLUDE_RE is set and excluded 0 of N files",
escalating to a hard refusal under `EXCLUDE_STRICT=true`. QA's `EXCLUDE_RE` carries five
alternatives; `Template`, `secret_manager` and `shared` match, so the count is non-zero,
so the guard never fires and `EXCLUDE_STRICT` is never consulted — while `employee` (vs
master's `300-Employee`) and a `Brand/` clause whose files moved to `100-Brand/` match
nothing. QA therefore selects the entire Employee pipeline it means to skip, has **zero**
Employee variables, and the apply refuses those files inside a hook Job whose log Argo
deletes.

The lesson is sharper than "print the measurement beside the threshold": **a single regex
cannot be validated per alternative, so it cannot carry this guard at all.** The fix is a
different data shape — a LIST, one entry per line, each required to match ≥1 discovered
file. Then the dead entry is named and counted. Draft and harness:
`wip/onprem-app-cicd/exclude-list/apply-exclusion-block.sh`. Related:
[[validator-checks-every-value-not-the-selected-ones]], [[proxy-is-not-the-property]].

## 2026-10-20 — "no checkout on this box" when the checkout was right there

A handed-over block tested `[ ! -f scripts/discover-cloud-app.sh ]` and, on a miss, printed
`NOT MEASURED - no ~/eks_code checkout on this box`. The checkout existed — `git` had just
run inside it and named its branch. **Three faults were collapsed into one message:**

| Fault | What it needs |
|---|---|
| no checkout | clone it |
| checkout present, on a branch with no upstream (`git pull` printed exactly that) | set the upstream, or fetch explicitly |
| **the file was never pushed at all** | push it — the actual cause, four commits sitting in the codespace |

The message named the first and the truth was the third, so the fix it implied was useless.
And the one line that *did* carry the answer — *"There is no tracking information for the
current branch"* — was printed by `git pull` and read as noise before the verdict.

**How to apply.** A missing-file guard must say what it checked: print the path, whether the
directory exists, and the branch. One line each, three facts, no verdict:

```bash
echo "dir:    $([ -d ~/eks_code ] && echo present || echo absent)"
echo "branch: $(git -C ~/eks_code rev-parse --abbrev-ref HEAD 2>&1)"
echo "file:   $([ -f ~/eks_code/scripts/x.sh ] && echo present || echo absent)"
```

**And check the delivery before blaming the destination.** Before handing over anything that
reads a repo file, confirm the file is actually on the remote:
`git cat-file -e origin/<branch>:<path>`. An unpushed script is indistinguishable, from the
far end, from a broken checkout — and it is the more likely of the two.

Related: [[transport-failure-not-a-verdict]], [[handing-over-commands]] mode 3 and the
"name WHICH fault" rule it already carried.

### Same turn, second instance: `for` over an empty list is a silent success

`for C in $(kubectl config get-contexts -o name | grep -i prod); do … done` printed
**nothing at all** — no header, no count, no error, exit 0. The `grep` matched no context, so
the body never ran. The operator saw a blank line and I had no measurement to reason from.

A loop is a guard too. **Print the list and its length before iterating**, never inside:

```bash
L=$(kubectl config get-contexts -o name | grep -i prod)
echo "matched: $(printf '%s\n' "$L" | grep -c .)"
printf '%s\n' "$L" | sed 's/^/  /'
```

Two instances in one handover — "no checkout" over a present checkout, and silence over an
empty match — both of them a block that produced *no measurement beside its verdict*. That is
the single rule: a handed-over block prints what it saw, then what it concluded, and never
only the conclusion.

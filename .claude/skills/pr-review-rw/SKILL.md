---
name: pr-review-rw
description: Review a PR that touches the on-prem cluster (especially RW namespaces). Runs the protect-RW workflow — identify the target namespace, independently verify against live cluster + source repo, draft Round-N review comment in the BLOCKER/CLEARED/ADVISORY format, document in wip/, update memory. Triggered by `/pr-review-rw <repo> <PR#>` or `review PR #N on <repo>`.
---

# /pr-review-rw

Structured review for PRs that touch on-prem cluster state — especially anything in or near `risingwave` (Tim's) or `risingwave-2` (Doke's) namespaces, or any cluster-wide platform change.

This skill encodes the workflow proven on PR #7 review (2026-05-29) where independent verification caught two findings Idris's reply alone would have missed (orphan ExternalSecret + dead postgres HR).

## When to use

- The user asks to review a specific PR (`/pr-review-rw <repo> <PR#>`, or "review #7 on iaac-talos-flux-cluster").
- The user is about to approve a PR and wants the protect-RW pass first.
- A PR has been updated and a Round-2/3 review is needed.

## When NOT to use

- Pure documentation PRs.
- PRs on repos unrelated to op-usxpress-dev.
- PRs that the user explicitly says don't need protect-RW scrutiny.

## Environment constraint

**Codespace cannot reach the cluster.** All live-cluster verification (kubectl, aws) must run on WSL. This skill presents copy-paste blocks for the user to run there.

## The workflow

### Phase 1 — Read the PR and identify scope

1. Run on WSL: `gh pr view <PR#> --repo <repo> --json title,state,headRefName,baseRefName,headRefOid,mergeable,reviewDecision,commits`.
2. Run on WSL: `gh pr diff <PR#> --repo <repo>` — capture the full diff.
3. Identify what changes, what resources it touches, what cluster state it would affect.

### Phase 2 — Identify the target namespace (Tim coord gate)

The rule (from [[feedback_protect_rw_onprem_workload]]):

| Target ns | Tim coord required? |
|---|---|
| `risingwave` (Tim's) | ✅ Yes |
| `risingwave-2` (Doke's IaC) | ❌ No |
| Cluster-wide / platform with possible RW impact | ✅ Yes |
| Other | Case-by-case |

For Kustomization-based PRs, target ns is determined by the SOURCE repo's manifests, not the Kustomization file. Verify by cloning the source repo + grepping namespace fields:

```bash
gh repo clone <source-repo-org>/<source-repo> /tmp/<source-repo> -- --depth 1 --branch <branch>
grep -E "^\s*namespace:" /tmp/<source-repo>/<path>/*.yaml | sort -u
cat /tmp/<source-repo>/<path>/namespace.yaml
```

**Don't trust the PR author's word on which ns; verify.**

### Phase 3 — Independent verification (TRUST BUT VERIFY)

This is the high-leverage step. Don't accept the PR author's claims; check the live cluster yourself.

For each claim made by the PR or its description, generate a verification command and run it. Standard battery:

```bash
# Baseline — RW Running?
kubectl get rw -A
kubectl get pods -n <target-ns> -o wide

# What does live state actually show?
kubectl -n <target-ns> get <resource> -o jsonpath='{...}'

# Is the bucket/secret/secret-ref/version the PR patches against actually what's running?
# Construct comparison: live value vs PR patch value

# Recent activity — has the author already pre-applied?
kubectl get events -n <target-ns> --sort-by=.lastTimestamp | tail -30
```

For source-repo manifests, also verify against the cloned source — does the CR / HR / config the PR patches actually exist with the field paths assumed by the patches?

### Phase 4 — Build the findings table

| # | Item | State | Severity | Notes |
|---|---|---|---|---|
| 1 | <description> | OPEN / CLEARED / FIXED | BLOCKER / Advisory / Lint | <evidence> |

Mark CLEARED only when independently verified (not just "PR author says it's fine").
Mark BLOCKER only for items that affect correctness, data, or trust boundaries.

### Phase 5 — Draft Round-N comment

Use this structure:

```
Round N — <commit-sha> verified.

**Cleared ✅**
- <item> — <one-line evidence>
- ...

**Still open**
1. (BLOCKER) <item> — <description + ask>
2. (BLOCKER) <item> — <description + ask>
3. (advisory) <item> — <description + suggested follow-up>

**Coordination ask — before you merge, please confirm:**
- <branch-test confirmation>
- <Tim coord> (if ns = risingwave)
```

Save the body to a temp file on WSL, then `gh pr comment <PR#> --repo <repo> --body-file <tmpfile>` (heredocs with backticks tend to mis-terminate; --body-file is safer).

### Phase 6 — Document in wip/

Create or update:
- `wip/<initiative>/STATE.md` — current decision + blockers
- `wip/<initiative>/pr-<N>-review-<date>.md` — full audit trail (one file per PR, Round-N sections appended)

The wip doc is the source of truth across compactions — memory holds the summary + pointer.

### Phase 7 — Update memory

- One memory file per PR review (e.g., `prN_<short-name>_review_<date>.md`).
- Add a one-line index entry in `MEMORY.md` near the most-related anchor.

### Phase 8 — On approval

When all blockers clear + coord met:
- `gh pr review <PR#> --repo <repo> --approve --body "<approval message>"`
- Commit STATE.md update with "APPROVED" status.
- Suggest filing any advisory items as Idris-task tickets (`/idris-task`).
- Post-merge, update [[rw-manifest-landscape-2026-05-28]] (or equivalent reference memory) with the new cluster state.

## Reusable verification helpers

Two scripts live under `scripts/` to speed up Phase 3:

- `scripts/verify-rw-baseline.sh` — runs the standard RW health checks (CR status, pod ages, postgres wiring, stateStore, bucket). Paste-into-WSL block.
- `scripts/pr-touches-ns.sh <source-repo-url> <branch> <manifests-path>` — clones the source repo, prints every distinct namespace it manages. Used in Phase 2.

## Quality bar checklist (run mentally before posting Round 1)

- [ ] I confirmed the target namespace from the SOURCE manifests, not the PR description.
- [ ] For every numeric/string value in a patch, I have a kubectl command that confirms it matches live.
- [ ] For every Secret/ConfigMap reference, I traced it back to an ExternalSecret or source manifest and confirmed it's actually consumed somewhere.
- [ ] For every HelmRelease change, I checked the live release name + version.
- [ ] For JSON patch ops (`add` to `env/-`, `replace` to specific paths), I checked the source for whether the path / array currently exists.
- [ ] I gave Idris (or whoever) a concrete `kubectl` line to confirm — not just "please verify yourself."

## Anti-patterns to avoid

- **Approving on the PR author's word alone.** Independent verification caught 2 of 6 blockers on PR #7 that wouldn't have surfaced otherwise.
- **Trusting the diff hunk for whole-file state.** Diffs show changes only; for "did you fix the lint at line 5" type questions, read the full file.
- **Treating Tim coord as optional.** When ns = `risingwave`, it's mandatory ([[feedback_protect_rw_onprem_workload]]).
- **Mixing "code clears" with "coord clears".** Approval needs both gates clear; document them separately.
- **Round-1 comment that's a vague "looks risky."** Be specific: cite the exact line, name the exact mode of failure, give the exact verification command.

## Output

- Posted PR comment (Round N).
- Updated `wip/<initiative>/STATE.md` + review doc.
- Updated `memory/<initiative>_pr_review_<date>.md` + `MEMORY.md` index entry.
- On approve: optional Idris-task ticket drafts for follow-up advisories.

## Apply

- This skill is invoked when a user asks for a PR review on an on-prem-cluster-touching PR.
- Run all live-cluster commands on WSL; codespace can only reach GitHub.
- Always lean on `/idris-task` for advisory follow-up tickets, not inline scope-creep on the current PR.

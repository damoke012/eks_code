# UI Sprint 6 close — 2026-10-16

Sprint 6 ran 2026-10-05 to 2026-10-16. Eight tickets assigned to Doke; 11 in the sprint.
The other 61 tickets assigned to him have **no sprint** and were never in scope.

## Outcome

| Ticket | Outcome | Evidence |
|---|---|---|
| **1707** cicd vulns + Renovate | **CLOSED** | 0 open Dependabot alerts (read with stderr visible, exit 0, 40682 bytes); `renovate/major-github-actions-dependencies` rebased to `ahead 1 behind 0`, `publish-applier.yml` intact |
| **1705** SQL exists twice | **guard merged**, deletion blocked | `risingwave-pipeline#126` merged — Pipeline Query Runner no longer applies the mirror. Deletion needs Tim on `Brand/300-transform.sql` |
| **1708** trivy-action@master | code complete, awaiting review | `actions-collection#99`, `pre-commit pass`, reviewers Lazy Devs / papachoriusx / mlashore-usxpress. `--admin` does NOT bypass CODEOWNERS |
| **1703** RW upgrade readiness | **split** | successor **INFRA-1716** |
| **1704** cert alerting | **split** | successor **INFRA-1717** |
| **1696** build book | **split** | successor **INFRA-1718** (its second carry) |
| **1709** Helm via Argo CD | undecided | needs `SHOW SOURCES/SINKS` on QA, plus a wording decision |
| **1706** GHA IAM roles | not started | 3–4 terraform imports into 064859874041 |

Successors filed by `scripts/file-sprint6-successors.py --go`, each linked `Relates` to its
predecessor and each stating what the sprint achieved separately from what is left. They land
in the **backlog**, not the next sprint.

## What the sprint actually discovered

The tickets were written on 2026-10-09 and three of them were **wrong about their own scope**
by the time they were worked:

1. **1705 is not "delete the loser, one commit".** `pipelines/shared/` is read by
   `secret.yaml` and `user-access-deploy.yaml`; only `Brand`, `employee`, `Template` and
   `secret_manager` are unreferenced. I repeated the ticket's framing twice before measuring.
2. **`Pipeline Query Runner` is active** and applies the mirror on push to `master`, `qa` or
   `dev`. The duplication had a delivery mechanism, which the ticket does not mention
   ([[mirror-sql-has-its-own-apply-path]]). The workflow's own comments at lines 147-149
   already name the defect — "Two systems read pipelines/" — so it was known, just not
   ticketed.
3. **1709's DONE WHEN contradicts a deliberate decision.** It wants QA to pick up a digest
   "without a human touching anything but the merge button"; PR #122 made QA dispatch-only on
   purpose. The criterion is out of date, not the system.
4. **1707 was already nearly done.** Both "critical vulnerabilities" are closed, and the
   Renovate branch no longer deleted `publish-applier.yml`. Only the rebase was outstanding.
5. **1706 says "four roles" and names three.** The fourth is unnamed in the ticket.

## Proven

- `actions-collection` has Renovate onboarded (a live `renovate/*` branch), so a
  `renovate.json` was unnecessary — and the one I first wrote, with
  `enabledManagers: ["github-actions"]`, would have **switched off** every other manager it
  runs there. Removed before the PR opened.
- A subtractive `paths` change (`- '!pipelines/Brand/**'` etc.) preserves `canary/` and
  `_connectivity/`, which a narrowing to `shared/**` would have silently stopped triggering.

## Tested and killed

- **"pre-commit fails on master too, so it is not mine."** Killed: `gh run list --branch
  master` returns only *Dependabot Updates* rows — `pre-commit` does not run on master at
  all, so the comparison measured nothing. Read the WORKFLOW column, not the status.
- **"the yamllint failure is line-length."** Killed by reading the message: *too few spaces
  before comment: expected 2*. The line was 87 chars and fine. One space before `#` was the
  whole failure, and `--strict` turned the warning into exit 2.

## Traps

- `gh pr edit --add-reviewer` emits a **Projects (classic) deprecation** GraphQL error that
  says nothing about whether the reviewer was added. Verify with `--json reviewRequests`; the
  REST route `POST /pulls/<n>/requested_reviewers` avoids the failing field entirely.
- `2>/dev/null` on `gh api .../dependabot/alerts` turns a 403 into the same empty output as
  "no alerts". I wrote that into my own check after writing the skill section warning about
  it. Report exit code and byte count beside the result.
- `gh pr merge --admin` does **not** override a CODEOWNERS review requirement.
- A commit deleting files under a watched `paths:` glob is itself a push matching that glob,
  and diff-based detection presents the deleted files to the workflow. Change the trigger
  before changing the inputs.

---

## Executed 2026-10-16, verified at the destination

`close-sprint6-tickets.py --go` commented and transitioned four. Re-read via
`sprint6-detail.py` (the agile sprint endpoint, not a JQL on the status field):

    INFRA-1696  [Done]       INFRA-1705  [In Progress]
    INFRA-1703  [Done]       INFRA-1706  [In Progress]
    INFRA-1704  [Done]       INFRA-1708  [In Progress]
    INFRA-1707  [Done]       INFRA-1709  [In Progress]

**4 of 8 closed.** Successors INFRA-1716 / 1717 / 1718 exist in the backlog and must be
moved onto the next sprint by hand — the API does not place them.

Three of the four still open are waiting on **other people**, not on work:

| | Waiting on |
|---|---|
| 1708 | a `lazy-devs` approval on `actions-collection#99` (green, CODEOWNERS-blocked; `--admin` does not override it) |
| 1705 | Tim: is `Brand/300-transform.sql` still needed? |
| 1709 | one query — `rw-sql.sh qa "SHOW SOURCES;"` |
| 1706 | genuinely not started |

Also in Sprint 6 but not Doke's: **INFRA-1713 is UNASSIGNED** ("Shell script to sync AWS
Secrets Manager secrets into RisingWave"), so it will carry by default with no owner. And
**INFRA-1697** ("close the dev → QA edge cases before a prod cutover date", Idris) is the
ticket `PLAN-tim-qa-blast-radius-2026-10-15.md` answers — the work happened here and the
ticket does not know it.

---

## 1709 closed — QA measured, and a standing belief disproven

`scripts/rw-sql.sh qa` on op-usxpress-qa, 2026-10-16:

    SOURCES (2)  public.brand_source_kafka, public.activeresource_source_kafka
    MVs (4)      public.brand_mv_raw, public.brand_mv_state, public.brand_mv_flat,
                 public.canary_promotion_mv
    SINKS (1)    public.activeresource_sink

The Job is applying SQL, not merely reporting Succeeded. No Employee objects — correct, it is
excluded on QA. `canary_promotion_mv` means the promotion path has run end to end.

⛔ **This disproves [[green-hook-over-an-empty-cluster]]**, which claimed QA had 0 sources and
0 sinks and had never run a Brand pipeline. That was recorded as a hypothesis, carried for
weeks, and was wrong. The worry had the right shape — a green hook cannot prove rows — but
the inference ran backwards: "green does not prove present" never licensed "therefore absent."
One command and an `aws sso login` settled it.

1709 closed with one criterion **deliberately unmet and stated in the comment**: it asks for
QA to promote "without a human touching anything but the merge button", and PR #122 made QA
dispatch-only on purpose, because a single 10-minute tick could otherwise carry an image
ECR → dev → QA → prod-PR with zero soak. The criterion is out of date, not the system.

**Sprint 6 final: 5 of 8 closed** (1696, 1703, 1704, 1707, 1709).

| Still open | Blocked on |
|---|---|
| 1705 | Tim on `Brand/300-transform.sql`, then the deletion PR. The guard (#126) is merged |
| 1708 | a `variant-inc/lazy-devs` code-owner approval. Idris approved but is not a code owner, so it does not satisfy the rule; branch also needs updating (gh on this box has no `pr update-branch`) |
| 1706 | **no AWS profile on the box resolves to 064859874041**, so the roles cannot even be enumerated. Plus `var.apps` is `{}`, no tags, no backend |

## 1708 — the exact gate, so nobody re-walks this

`.github/CODEOWNERS` in `variant-inc/actions-collection` is `*  @variant-inc/lazy-devs`.
Classic branch protection returns **404**, so the rule comes from a repository ruleset, which
is also why `gh pr merge --admin` answers "Waiting on code owner review" instead of merging.

`lazy-devs` = `usx-devops stevebduckjr rsaini15 dare-x papachoriusx mlashore-usxpress`.

- **Doke IS a code owner** (`dare-x`), but he authored the PR and GitHub will not let an
  author's own approval satisfy the requirement.
- **`ifagbemi-usxpress` is NOT in the team**, so Idris's approval — given twice — cannot clear
  it. The PR shows `ifagbemi-usxpress: APPROVED` and `reviewDecision: REVIEW_REQUIRED`
  simultaneously, which reads like a bug and is not one.
- **Adding him to the team is not available to Doke**: `PUT /orgs/.../teams/lazy-devs/
  memberships/...` returns 403 "must be an organization owner or team maintainer" *after* a
  successful `gh auth refresh -s admin:org`. The refresh is what discriminates the two causes
  — before it, the same 403 also carried a scope hint, and the two are indistinguishable
  without eliminating one.

**Only path:** an approval from `stevebduckjr`, `rsaini15`, `papachoriusx` or
`mlashore-usxpress`. The last two are already requested reviewers.

Branch state is `BLOCKED` (not `BEHIND`) after merging master in, so review is the sole
remaining gate.

Worth raising separately: Idris does RisingWave work across this org and is a code owner
nowhere in it, so every review he gives costs a second person. That is an org-owner
conversation, not a blocker on this ticket.

## 1705 closed — the disputed file was empty

`Brand/300-transform.sql`, which INFRA-1705 is entirely written around, contains:

    /* NO CODE NEEDED */
    -- This file is intentionally left blank.
    -- Transformations for the Brand pipeline are handled in the 400-extract.sql file.

So the ticket's premise — "WHAT RUNS ON QA INCLUDES A TRANSFORM THAT IS NOT IN THE SOURCE OF
TRUTH" — was false. There is no transform. `risingwave-poc` lacks the file because there is
nothing in it. No owner decision was needed and nothing required porting.

`#127` merged: 24 files, 1667 lines. `shared/` and `canary/` kept. Archived to
`/tmp/rw-mirror-pipelines-2026-10-16.tar.gz`, and in git history regardless.

**The ticket was wrong about its premise and right that something was wrong.** Investigating
it is what surfaced the live `Pipeline Query Runner` applying the mirror to QA outside the
digest chain and outside the ledger — a real defect it never mentions.

**Sprint 6 final: 6 of 8** (1696, 1703, 1704, 1705, 1707, 1709).
Remaining: 1708 (one `lazy-devs` approval), 1706 (no AWS access to 064859874041).

---

## FINAL — 2026-10-19: 8 of 8

| Ticket | Closed on | Evidence |
|---|---|---|
| 1696, 1703, 1704 | 10-16 | split; successors INFRA-1718 / 1716 / 1717 |
| 1707 | 10-16 | 0 open alerts (measured with stderr visible); branch rebased, applier build intact |
| 1709 | 10-16 | QA has 2 sources, 4 MVs, 1 sink — objects at the destination |
| 1705 | 10-16 | `#126` guard + `#127` deletion; the disputed file was an empty placeholder |
| 1706 | 10-19 | six addresses imported, `No changes. Your infrastructure matches the configuration.` |
| 1708 | 10-19 | `actions-collection#99` merged; master line 106 reads `@57a97c7e…  # 0.35.0` |

### ⚠️ One loose end that outlived the sprint

**`iac-tf-manual-runs#39` is still open.** INFRA-1706's Terraform is applied — the roles are
tagged, the state is in S3 — but until that PR merges the config exists only on a branch. A
state file whose code is not in the repo is worse than the hand-made roles were, because the
next person finds state they cannot plan against. Needs an approval from `lazy-devs`.

Its `pre-commit` was **red for three days** and nobody said so. Four tflint warnings, all mine:
no `required_version`, no provider version constraint, and `variable`/`output` not split into
their own files. A PR with a red check is a PR nobody opens — the review did not stall on
willingness.

### The provider pin, and why it stopped being cosmetic

tflint's "Missing version constraint for provider aws" landed the same day the Kafka dev
deploy failed on a provider upgrade: OpenTofu called `lambda:ListVersionsByFunction` while
READING `ccloud-kafka-key-rotation`, a call older provider versions never made, and the deploy
died with nothing applied. Reverting the Lambda version stopped the question being asked; it
did not grant the permission.

`iac-tf-manual-runs` **gitignores `.terraform.lock.hcl`** (confirmed: `.gitignore:7`, and zero
other configs commit one), so in that repo the `required_providers` constraint IS the pin.
Without it every fresh `init` takes whatever is newest that day. Now `~> 6.69`, matching the
provider the state was built with.

Same defect class as `trivy-action@master` in INFRA-1708 — found twice in one week, in two
repos, by two different mechanisms, neither of them a person looking for it.

### Traps added this sprint

- `gh pr merge --admin` does **not** override a CODEOWNERS review when the rule comes from a
  repository **ruleset**. Classic branch protection returns **404** on such a repo, which reads
  as "no protection configured" and is the opposite.
- An approval from someone outside the owning team is recorded and does not count. The PR shows
  `APPROVED` and `REVIEW_REQUIRED` simultaneously.
- `yamllint --strict` fails a pin for *"too few spaces before comment: expected 2"*. One space
  before `#`. It reads as a content problem and is formatting.

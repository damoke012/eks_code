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

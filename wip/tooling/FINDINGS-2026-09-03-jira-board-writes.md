# Jira board writes — Sprint 4 update, 2026-09-03

Doing one ordinary task (put 2026-09-01/09-02's work on the board) surfaced three separate
ways a Jira write reports success it did not earn.

## What happened

The board was **two days stale**. INFRA-1674's last comment was 08-31, INFRA-1650's 08-24,
INFRA-1639's 08-21. Jira had no record that RisingWave was live on op-usxpress-prod, that the
prod Argo CD Git credential worked, or that SSO was live on all three clusters — all of which
had been done and written up in this repo.

Both scripts that were supposed to have recorded it existed, were committed, and had never
been run with `--go`. Commit `c8db76d` is titled *"record 2026-09-02 on the INFRA board:
three comments, one new ticket"*. Nothing was recorded.

## Proven

Scope: INFRA project, board 322, `usxpress.atlassian.net`, verified 2026-09-03.

| | |
|---|---|
| **UI Sprint 4 = sprint id 1041** | state `future`, 2026-09-01 → 09-12, **never started** |
| Sprint 4 contents before | 24 issues (6 In Progress, 17 To Do, 1 stray Done) |
| Sprint 4 contents after | 28 |
| Board 322 sprint ids | 4046 UI Sprint 0, 4047 UI Sprint 1, 6088 UI Sprint 2, 959 UI Sprint 3, **1041 UI Sprint 4**, 6155 On-Prem App Delivery (future, dates already past) |
| `GET /rest/agile/1.0/board?…` | **HTTP 500** — enumerate sprints per board id instead |

Landed on the board: comments on INFRA-1674, 1650, 1639; INFRA-1686 (Nutanix `dpl`/`jbtest`
cleanup), 1687 (console licence), 1688 (licence injection), 1689 (prod Grafana VirtualService
publishes a dev hostname); `1687 blocks 1688`; all four added to sprint 1041.

### 1. A bad token is indistinguishable from a permissions problem

An unauthorised **read** returns `404 "Issue does not exist or you do not have permission to
see it"`. An unauthorised **create** returns `400 "The target project doesn't exist or you
don't have permission to create issues in it."` Neither says *bad token*.

Nine calls failed that way and every message pointed at permissions. The token was the
literal string `<the token you pasted>` — a placeholder handed over in a runnable command,
which is what CLAUDE.md rule 6 exists to prevent.

**This was the second occurrence.** `close-sprint3-tickets.py:269` has carried a `preflight()`
since 2026-08-20, when the same placeholder cost eleven calls. Its docstring describes this
failure exactly. The two scripts that failed on 09-03 were written later, each with its own
copy of `api()`, and never called it.

> A check that lives as a docstring in one module does not reach the next module.

### 2. API-created tickets land in the backlog, never the sprint

Four tickets were created and the sprint stayed at 24. Already known
(`wip/standup-2026-07-13/ticket-reconciliation.md`), and it recurred anyway, because the
remedy — `add-to-sprint.py` — resolved only `state=active` and **exits** on a future sprint.
Sprint 4 has never been started, so the one tool for the job refused the one sprint that
needed it. Now takes `--sprint <id>`.

### 3. `openSprints()` silently misses a sprint that was never started

`list-open-tickets.py` returned 15 open tickets and looked authoritative. Its JQL is
`parent = INFRA-1632 OR sprint in openSprints()`; with Sprint 4 in `state=future`,
`openSprints()` matched nothing and every result came from the epic clause. All 24 Sprint 4
issues were invisible, with no error and no empty-result warning.

## Tested and killed

- **`sed '/preflight/d'` as a regression probe for the new linter** — the probe reported the
  linter clean. The linter was fine; the probe was not. `sed` removed the lines containing
  the word `preflight` but left `s, r = api("GET", "/rest/api/3/myself")`, which the linter
  also accepts. Replaced with a synthetic 6-line script that has `atlassian.net` and a
  `"POST"` and nothing else. It fires, and goes green when the probe is deleted.
- **Running the writes from the codespace** — refused by the harness in auto mode. Not worked
  around; run from WSL by Doke.
- **Assigning the five unassigned on-prem tickets** — the script reported "already assigned
  to dare" for 1655/1660/1661/1662/1663. They read as *unassigned* ~15:30 the same day and
  neither script changed them. **Unexplained: another writer is touching this board.** Not
  investigated; recorded rather than guessed at.

## Traps

- **`authenticated as …` is the only proof the token works.** Every mutating Jira script now
  calls a preflight against `/rest/api/3/myself` and exits 1 before writing. Enforced by
  `scripts/lint-jira-preflight.sh`; ten scripts were missing it, all ten now have it.
- **Never hand over a command containing `<…>`.** This cost the whole first attempt. The same
  message also handed over `cd /workspaces/eks_code` (a codespace path) and two
  `settings.json` permission entries formatted as shell commands — all three were pasted into
  a WSL prompt verbatim, and all three were mine.
- **A committed script is not a completed action**, and its commit message is not evidence.
  See `proxy-is-not-the-property`, instance 7.
- **`--no-comment`** on `update-sprint4-tickets.py`: it and `jira-update-2026-09-02.py` carry
  the same INFRA-1674 evidence. Run both without it and the ticket gets the comment twice.
- **A sprint whose dates have started may still be `state=future`.** Dates are not state.

## Still open

- Close INFRA-1650 (verified done). Start Sprint 4. Drop INFRA-345 (Charlie's Done RPA
  ticket from 2024-04-09). Set an owner on INFRA-1687 — vendor licence, Steve → Zach.
- Who assigned the five tickets on 09-03.
- `scripts/push-to-confluence.sh:1` holds a live Atlassian token in plaintext. Untracked, so
  not in git, but `add-to-sprint.py` silently falls back to reading it — a script can
  authenticate with no token in the environment and no indication of where it came from.

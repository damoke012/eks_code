---
name: jira-board-sprint-topology
description: "INFRA board 322 sprint ids and the three ways a Jira write reports success it did not earn — bad token reads as 404/permissions, API-created tickets land in the backlog, openSprints() misses a sprint that was never started"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 47b0e9a0-2e5c-4874-83f1-06d3268ab121
  modified: 2026-09-03T16:48:29.944Z
---

`usxpress.atlassian.net`, project INFRA, **board 322**. Verified 2026-09-03.

Sprint ids: 4046 UI Sprint 0, 4047 UI Sprint 1, 6088 UI Sprint 2, 959 UI Sprint 3,
**1041 UI Sprint 4** (2026-09-01 → 09-12), 6155 "On-Prem App Delivery".
`GET /rest/agile/1.0/board` returns **HTTP 500** — enumerate per board id
(`/rest/agile/1.0/board/322/sprint?state=active|future|closed`).

**A sprint whose dates have started may still be `state=future`.** UI Sprint 4 was never
started. Three consequences, each of which produced a clean, confident, wrong result:

1. **`openSprints()` matched nothing**, so `list-open-tickets.py` returned only its epic
   clause — 15 tickets, no error — while Sprint 4's 24 were invisible.
2. **API-created tickets land in the project backlog, not the sprint.** Four were created
   and the sprint stayed at 24. The remedy, `add-to-sprint.py`, resolved only `state=active`
   and exited on a future sprint; it now takes `--sprint <id>`.
3. **A bad token is indistinguishable from a permissions problem.** An unauthorised read is
   `404 "Issue does not exist or you do not have permission to see it"`; an unauthorised
   create is `400 "The target project doesn't exist…"`. Neither says *bad token*.

**How to apply:** `authenticated as …` is the only proof the credential works. Every mutating
Jira script now preflights `/rest/api/3/myself` and exits 1 before writing —
`scripts/lint-jira-preflight.sh` enforces it (ten scripts were missing it on 2026-09-03,
including one written *after* the same failure in August: the first capture was a docstring
in one module and never reached the next). Then verify the remote, never the script:
`check-sprint-membership.py <id>`.

`scripts/push-to-confluence.sh:1` holds a live token in plaintext (untracked). Some scripts
silently fall back to it, so a run can authenticate with nothing in the environment.

Related: [[proxy-is-not-the-property]] (instance 7 — a commit message is not the write),
[[adjacent-step-green-signals]], [[transport-failure-not-a-verdict]].
Note: `wip/tooling/FINDINGS-2026-09-03-jira-board-writes.md`.

---

## 2026-09-19 — the board has never started a sprint, and that is why `active` is empty

Board **322 "UI board"** (scrum) is the INFRA sprint board. Also on the project: **375
"Infra"** (kanban, no sprints) and **589 "Jeff Peterson Team Work"** (scrum).

⚠️ **Every sprint on 322 has gone straight from `future` to `closed` — none was ever
STARTED.** So `GET /board/322/sprint?state=active` returns **zero**, permanently, and any
tool keying on the active sprint silently finds nothing. UI Sprint 4 (1041) held 27 issues
with dates that had passed on 12 September and was still `future`: the working sprint in
everything but the flag.

**A `future` sprint cannot be closed.** The API refuses. Start it (`{"state":"active"}`)
then close it (`{"state":"closed"}`) — that keeps the sprint report and the completed-issue
history, which deleting it would throw away. Move the not-done issues to the backlog
*first* (`POST /rest/agile/1.0/backlog/issue`): Jira's completion dialog asks a human where
they should go, the API close does not.

**Selecting the sprint:** exactly one `active`, else the single `future` sprint that HAS
issues. An empty `future` sprint is a placeholder — `On-Prem App Delivery` (6155) has sat
empty since August and is never the answer.

Rollover run 2026-09-19: UI Sprint 4 → 23 to backlog, 4 done retained, closed.
**UI Sprint 5 = 6223** (2026-09-21 → 2026-10-02) holding INFRA-1696 (Doke, on-prem cluster
docs + IaC rewire), INFRA-1697 and INFRA-1698 (Idris, RW pipeline / RW alerting).

Tool: `scripts/jira-sprint-rollover-2026-09-21.py` — `--list` surveys read-only, `--go`
writes, `--sprint <id>` overrides selection. Its `adf()` keeps single newlines as hardBreak
nodes; the shared helper in `close-sprint3-tickets.py` splits only on blank lines and
collapses every bullet list onto one line.

## Rollover 2026-10-05 — carry forward, not reset

**UI Sprint 5 (6223) closed with 0 of 3 done.** All three carried into **UI Sprint 6 = 6290**
(2026-10-05 → 2026-10-16): INFRA-1696 (To Do), INFRA-1697 (To Do), INFRA-1698 (In Progress).
Two weeks, nothing completed. `On-Prem App Delivery` (6155) deleted, 204.

Tool: `scripts/jira-sprint-rollover-2026-10-05.py`. Differs from the September one in the
destination: incomplete issues go into the NEW SPRINT, not the backlog. Order is create
sprint → move issues in → close the old one, for the same reason the September script moved
to the backlog first — the API close never asks where they should go.

Closing the already-done issues is best-effort and looks the transition up **per issue**:
the INFRA workflow does not offer the same transitions from every status, and a hardcoded
transition id is how a rollover half-finishes. On this run it was a no-op — nothing was done.

**Getting the script to WSL is its own problem.** The codespace commit has to reach
`origin` first, and WSL's git is `dare-x` while the repo is `damoke012`, so a push from
there 403s. When that path is blocked, `gzip -9c | base64 -w0` into a **single-line**
`echo '<b64>' | base64 -d | gunzip > path` survives Doke's WSL where a heredoc mangles —
then prove it with `sha256sum` and `python3 -m py_compile` before running. 11KB → 6KB of
base64. See [[prose-through-shell-strings]].

### ⚠️ The ordering defect, and why it could not be repaired

The first run of the 2026-10-05 script moved the unfinished issues into the new sprint and
closed the old one afterwards. `POST /rest/agile/1.0/sprint/{id}/issue` **replaces** an open
sprint association rather than adding to it, so **UI Sprint 5 closed holding zero issues** —
no commitment, no carry-over, no velocity line for those two weeks.

**A closed sprint on Jira Cloud is terminal.** Both repair paths are refused:

```
POST /sprint/6223 {"state":"active"}   -> 400 Transitioning from CLOSED state to ACTIVE state is not supported
POST /sprint/6223/issue {...}          -> 400 You must specify a sprint which has not been completed
```

No credential changes that. **Get the order right the first time: close, then create, then
move.** Jira keeps CLOSED sprints in an issue's sprint history, so the old record survives.

What IS recoverable: each issue's **changelog** still shows the Sprint field transition
(`UI Sprint 5 -> UI Sprint 6`, 2026-10-05). The aggregate sprint report is gone; the audit
trail is not. A saved JQL filter on the issue keys reconstructs the view.

⚠️ **UI Sprint 4 (1041) shows 4 of its 27** for the same mechanical reason, but by design —
that rollover's destination was the backlog, so moving out first was correct and what remains
is the completed set. The two look identical in a dry run and are not the same thing. The
destination decides the order: **backlog → move first; next sprint → close first.**

### 2026-10-06 — the Sprint field is `customfield_10010`, and a wrong id is not an error

INFRA-1703 was created and added to UI Sprint 6 (6290), `204`. The verification read asked
for `fields=summary,sprint,customfield_10020,status` and came back **200 with neither
`sprint` nor `customfield_10020` present** — Jira silently drops field names it does not
recognise instead of rejecting the request. An issue genuinely in no sprint returns exactly
the same shape, so that response is indistinguishable from the failure it was meant to
detect. Another instance of [[adjacent-step-green-signals]].

- `GET /rest/api/2/field` → **Sprint = `customfield_10010`** on this instance. There is no
  field named `sprint`; that name reads as a typo and vanishes.
- **Verify at the destination, not on the issue:**
  `GET /rest/agile/1.0/sprint/<id>/issue?fields=summary,status&maxResults=100` and grep for
  the key. It cannot be satisfied by a misspelling, and it is the thing the board renders.

**How to apply:** when a Jira read is the proof of a write, never let a field name be the
load-bearing part of it. Ask the collection that is supposed to contain the issue.

## Sprint rollover, measured 2026-10-19 (UI Sprint 6 -> 7, new sprint id 6296)

- **`/rest/agile/1.0/sprint/{id}/issue` LAGS a write by seconds.** Adding three issues
  returned `HTTP 204` and the very next `total` read `10` instead of `13`. Minutes later both
  the listing and each issue's `customfield_10010` said all 13. **A count taken immediately
  after a 204 reads as a failed write and is not one** — re-read before concluding, and check
  both ends ([[adjacent-step-green-signals]]).
- **A newly created sprint is `future`, not `active`.** Looking it up with `?state=active`
  finds nothing and leaves the id empty, which then builds the URL `/sprint/issue` and 400s.
  UI Sprint 6 had *also* never been started, which is why it had no usable report until it was
  closed — the API starts it first, because a `future` sprint cannot be closed.
- **Creating a sprint does not start it.** `POST /sprint/{id}` with `{"state":"active"}` is a
  separate call, and skipping it is how Sprint 6 ended up reporting nothing for two weeks.
- Issues filed by API land in the **backlog**, so a successor ticket is NOT in the old sprint
  and will not be carried by a rollover. Add it to the new sprint explicitly.
- `scripts/jira-sprint-rollover-2026-10-19.py` is the current copy; only the two date
  constants change per sprint.


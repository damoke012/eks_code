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

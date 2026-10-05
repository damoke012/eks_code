# UI Sprint 5 closed holding zero issues, and a closed sprint cannot be reopened

**2026-10-05.** Found immediately after running the sprint rollover: the board showed
`6223 closed 0 issue(s)` where it should have shown three committed and none completed.

Scope: Jira Cloud, `usxpress.atlassian.net`, project INFRA, board 322. Measured 2026-10-05.

---

## What is proven

### 1. Adding an issue to a sprint REMOVES it from its current open sprint

`POST /rest/agile/1.0/sprint/{id}/issue` replaces the open-sprint association rather than
adding to it. So moving the unfinished issues into UI Sprint 6 **before** closing UI Sprint 5
emptied Sprint 5, and the close then had nothing to record.

Result: 3 issues committed, 0 completed, and a sprint report showing neither.

### 2. A closed sprint is terminal. Both repair paths are refused.

```
POST /rest/agile/1.0/sprint/6223 {"state":"active"}
  400  Transitioning from CLOSED state to ACTIVE state is not supported

POST /rest/agile/1.0/sprint/6223/issue {"issues":[...]}
  400  You must specify a sprint which has not been completed.
```

No credential changes this. It is not a permissions problem, and checking that a closed
sprint is one-way **before** offering a repair sequence would have saved two failed calls.

### 3. The changelog survives

Each issue's History still records `Sprint: UI Sprint 5 -> UI Sprint 6` with its timestamp.
The aggregate report is gone; the audit trail is not. A saved JQL filter on the issue keys
reconstructs the view the sprint filter would have given.

---

## What we believed that was wrong

- **"Moving the issues out before the close is the safe order."** It is — when the
  destination is the backlog. The September rollover did exactly this and was correct,
  because what should remain on a reset sprint is the completed set. When the destination is
  the next sprint, the same order destroys the record. **The destination decides the order.**
- **"The repair is probably available."** Offered as likely before testing it. It is not
  available at all, and the two 400s were the cheapest possible check — they should have come
  before the suggestion, not after.

---

## Did a procedure change

Yes. `scripts/jira-sprint-rollover-2026-10-05.py` now runs:

1. close the done issues
2. **close the old sprint, with the unfinished issues still in it**
3. create the next sprint
4. move the unfinished issues into it

Jira keeps CLOSED sprints in an issue's sprint history, so the old record survives step 4.

The failure messages changed with it: the old ones said "the carry-over already ran", which
is no longer true at that point and would have sent the next person to the wrong place.

---

## Could a check have caught it

Yes, and the dry run did not. The dry run printed the plan in the wrong order and read as
correct, because both orders produce the same end state for the ISSUES — only the sprint's
record differs, and nothing in the preview showed it.

The check that would catch it is a post-run assertion: after `--go`, read the closed sprint's
issue count and fail loudly if it is zero while issues were carried over.

---

## Proven

- `POST /sprint/{id}/issue` replaces, not appends, for an open sprint.
- `state: closed -> active` is refused by Jira Cloud (HTTP 400).
- Adding an issue to a completed sprint is refused by Jira Cloud (HTTP 400).
- UI Sprint 5 (6223): closed, 0 issues. Every other closed sprint on board 322 retains its
  issues; UI Sprint 4 (1041) shows 4 of 27 for the same mechanism, by design.

## Tested and killed

- **"Reopen the sprint, re-add, re-close in the right order."** Both calls return 400.
- **"A token with more rights would do it."** It is not an authorisation failure.

## Traps

- **The destination decides the order.** Backlog -> move first. Next sprint -> close first.
  The two rollovers look identical in a dry run.
- **A closed sprint is one-way.** Verify the order before `--go`, because there is no undo.
- **`openSprints()` is empty on board 322.** Sprints go `future` -> `closed` and are never
  started, so any filter or automation keyed on the open sprint silently finds nothing.

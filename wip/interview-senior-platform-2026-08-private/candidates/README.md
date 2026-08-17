# Candidate submissions

One folder per candidate, per round. **Private — never publish. Contains assessments of named
individuals; keep it out of the candidate repo and off any shared screen.**

```
candidates/
  README.md                       this file - criteria and how to run it
  _TEMPLATE/EVALUATION.md         copy this per candidate
  YYYY-MM-DD-<github-handle>/
    EVALUATION.md                 the scorecard
    submission/                   their code, exactly as they left it
    notes.md                      raw observations during the round (optional)
```

## The format, as of 2026-08-17

Exercise 01 only, roughly an hour. If they do well, invite them back for 02-05.

That is a deliberate narrowing, not a compromise: Exercise 01 is the client-ID incident, it requires
them to write the fix, and it leads directly into 02 (the same failure from the consumer side), 03
(what a "clean redeploy" destroys), 04 (why nothing alerted) and 05 (how to design it away). One
exercise, done properly, tells you whether the rest is worth booking.

## The three things we score

| # | Criterion | What it means | Evidence to keep |
|---|---|---|---|
| **1** | **Understands the problem** | Can they explain why a hand-maintained client ID in a manifest beats the one the platform generates, and why redeploying can't fix it | What they said, in their words. Quote it |
| **2** | **Designs a sound solution** | Where they draw the line between too strict and too loose, and whether they can defend it. The tenant-ID exception lives here | Their reasoning, and whether it survived a challenge |
| **3** | **Writes the code** | Working Go that catches the bug, follows the file's conventions, keeps `errors.Join`, and is tested | The diff |

They are scored separately and **a candidate can pass 1 and 2 while failing 3.** That combination is
worth discussing rather than auto-rejecting - it describes a strong architect who is rusty in Go.
The reverse (3 without 1) is worth less than it looks: code that passes the tests without
understanding the incident won't generalise to the next one.

Score each 1-4. **3 is the bar.**

| | 1 | 2 | 3 | 4 |
|---|---|---|---|---|
| **Understands** | needs the problem explained more than once | restates the brief | explains the mechanism in their own words | connects it to failure classes beyond this one |
| **Designs** | no rule, or "block all GUIDs" | one condition, no trade-off named | both key and value, names the trade-off | spares TENANT_ID with a reason, or inverts to platform-supplied names |
| **Codes** | can't compile in the time | compiles, unidiomatic, untested | idiomatic, tested, follows conventions | package-level regex, sorted keys, table-driven boundary tests |

## Collecting the code

At the end of the exercise, ask them to run this in their codespace and paste the output into the
chat:

```bash
cd /workspaces/interview-senior-platform/exercises/01-go-spec-guard
git diff
```

That captures exactly what they changed. Save it to `submission/` verbatim - do not tidy it, do not
fix their syntax. The state they left it in is the evidence.

If the round ends without a clean capture, save whatever you have and **label it as partial**. A
screen-share transcription is not the same artefact as their file, and comparing a transcription
against someone else's real diff is not a fair comparison.

## Comparing across candidates

Keep the scores per criterion, not as a single number. When you have three or four, the useful
question is not "who scored highest" but "who was strong on the thing we are actually short of".
Note that on each scorecard rather than trying to reconstruct it later.

# Candidate comparison — recovered 2026-10-14

**Provenance:** Rob and Spencer were scored on 2026-10-13 18:55–18:58. That assessment existed
**only in a session transcript** (`~/.claude/projects/-workspaces-eks-code/47b0e9a0….jsonl`,
lines 28108 and 28121) and was never written into `candidates/`. Recovered and recorded here so
the next comparison starts from a file.

## Two different scoring frames are in play — the two 60s are NOT the same 60

| Frame | Used for | Weights |
|---|---|---|
| August | Mar Sanchez (60/100) | understanding 25 · coding 25 · architecture 25 · effort 25 |
| October | Rob (~60) · Spencer (~42) | understanding **50** · coding **20** · platform **30** |

This was flagged on 10-13 as process item 5 (*"the rubric needs to be per role"*) and is now
actively confusing the ranking. Pick one frame per seat before the next round.

## The October three

| | **Rob** (`newtorob`) | **Spencer Smolen** | **André Leroux Gibson** |
|---|---|---|---|
| Date | 2026-10-13 | 2026-10-13 | 2026-10-14 |
| Understanding /50 | read accurately; proposed **two wrong fixes** (move to Helm; make hardcoded values authoritative) | **22** — inverted model at 0:48, built 5 min on it; found `validateUI` by reading; needed 4 passes to be told | **not assessed** — never stated; at 9 min left the notes were still prompting for it |
| Coding /20 | compiles, right structure, **wrong discriminator** | **6** — likely doesn't compile, one hardcoded key, echoes the identity into logs, rejects on key presence | **not attempted** — exercise opened with ~30 min left |
| Platform /30 | **strong** — crash loop, artifact promotion carried through environments | **14** — upgrade as "rolling update", Argo-green as "check logs", S3 as "CSI driver" | **not reached** — platform questions come last in the structure |
| Total | **~60** | **~42** | **unscoreable** |

**Neither Rob nor Spencer understood the problem unaided.** Both had to be told. That is 50% of
the October frame and it is the dimension neither cleared.

## Ranking as it stood on 10-13

1. **The earlier mid-level candidate** — got the problem **unaided**, weak code. On the October
   weighting that outranks both: understanding is 50, bad code costs at most 20.
2. **Rob** — real operational depth. A yes at senior engineer, a **no** at architect.
3. **Spencer** — evolvable, but the team already has junior engineers.

Plus the **Parool** option, which you and Meredith judged strongest of everything discussed —
with the caveat that the title and pay must match the role she would actually do.

## Where André sits

**Nowhere yet, and that is not a judgement of him.** The round never reached any scored
dimension. Ranking him last would be ranking the access failure, not the engineer — and the
`candidates/README.md` rule cuts the same way it did for Mar Sanchez.

## ⛔ THREE CONSECUTIVE ROUNDS LOST TIME TO REPO ACCESS

| Round | Failure |
|---|---|
| 2026-08-17 Mar Sanchez | GitHub account created 2 min before the invite |
| 2026-10-13 Rob | invited to the **wrong repo**, accepted it, saw the other exercise set, invite cancelled and re-sent |
| 2026-10-14 André | ~7.5 min across 2 accounts and 3 authenticators; invite sent to the account he could not 2FA into |

Twice now the invite went to the wrong place. `CANDIDATE-WORKFLOW.md` was also found on 10-13 to
document `permission=pull`, which a personal repo rejects — **the documented process cannot work
as written** and may still be uncorrected.

**Fix before the next round:** send the invite 48h ahead, name the repo explicitly, and require a
reply confirming the candidate can open it. Until then every candidate is partly scored on
GitHub's 2FA flow and the rounds are not comparable to one another.

## Still unrecorded from 10-13
- The candidate who **reapplied under a different name**. Flagged that day as needing a durable
  note; still not written anywhere.
- Mar Sanchez's real `git diff` and his criteria-1 quote — the August hold has been open 8 weeks.

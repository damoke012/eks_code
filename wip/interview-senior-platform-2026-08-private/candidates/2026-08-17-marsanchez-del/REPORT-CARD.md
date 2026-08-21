# Report card — Mar Sanchez (`marsanchez-del`)

**Role:** Senior Platform Engineer · **Round:** Exercise 01 only, ~1 hour · **Date:** 2026-08-17
**Interviewer:** Dare Oke · **Card compiled:** 2026-08-21

> ## ⚠️ Read this before reading the scores
>
> **The artefact is a partial screen-share transcription, not a `git diff`.** It starts at
> `func validateUI` and the round was still running when it was captured. It may not be his
> final state.
>
> **Two of these four dimensions have almost no contemporaneous evidence.** Criteria 1 and 4
> were observed in conversation and never written down; the only surviving note is the
> interviewer's line *"He did well with 1."* Everything else in those two sections is
> inferred from the code, which is a poor instrument for either.
>
> **Scores 1 and 4 are therefore provisional and the interviewer's own recollection
> outranks them.** Scores 2 and 3 are firm — they rest on the artefact and were verified
> against a Go toolchain on 2026-08-21.
>
> **Do not compare this card to a candidate who submitted a clean `git diff`** without
> adjusting for that, or the comparison is rigged against him.

---

## Scores

| # | Dimension | Score | Confidence |
|---|---|---:|---|
| 1 | Understands the problem | **18 / 25** | Low — inferred, not observed |
| 2 | Coding skills | **7 / 25** | High — verified mechanically |
| 3 | Architectural decisions | **12 / 25** | High — visible in the artefact |
| 4 | Effort | **15 / 25** | Very low — barely evidenced |
| | **Total** | **52 / 100** | |

**Band:** below the bar for Senior Platform Engineer **on this evidence**. Not a clear
decline — see *Recommendation*.

---

## 1. Understands the problem — 18 / 25

**What earns it.**

- The interviewer's contemporaneous assessment was *"He did well with 1."* That is the
  single strongest piece of evidence on this dimension and it is positive.
- His error message is the giveaway that he understood the *purpose*, not just the pattern:
  *"Client ID and OAuth identities are managed by the platform and should not be manually
  configured."* He grasped that the guard exists to redirect a developer, not merely to
  reject a string. Many candidates emit `invalid value` and move on.
- He anticipated the **scope-suffix** shape unprompted — that an identity can appear as
  `api://<guid>/.default`, not only as a bare GUID. That is a second-order insight about
  the problem domain and several candidates will not reach it.

**What costs it.**

- No evidence he identified the **tenant-ID discriminator** — that `VITE_AUTH_TENANT_ID`
  is also a GUID and *should not* be flagged. This is the distinction the exercise is built
  around. The evaluation's prompts for it (*"Did he spare it? unprompted / after a hint /
  no"*) were left blank, so we cannot say he missed it — only that nothing records him
  getting it.

**Why 18 and not higher:** the ceiling on this dimension is set by the missing evidence,
not by anything he did wrong. If the interviewer recalls him naming the tenant-ID trap, this
should move to 22–24.

---

## 2. Coding skills — 7 / 25

Verified against go1.26.4 on 2026-08-21, not taken on trust.

**Would not compile:**

| Defect | Line |
|---|---|
| Three named `func` declarations nested inside `validateUI` — Go has no nested named functions | 15, 33, 47 |
| `func(s*Spec) Validate () []error` — malformed receiver, **and redeclares** the existing `Validate` | 47 |
| `var errors []errors` — package name used as a type, and shadows the imported `errors` | 49 |
| `if s.UI! =nil` — `!=` split by a space | 51 |
| `fmt.Errorf("ui.configVars". %s …` — `.` where a `,` belongs; string literal broken across lines | 41–43 |

**Two correctness bugs that are not typos — this is what the score turns on:**

- **The GUID regex is short one group.** It reads `8-4-4-12`; a GUID is `8-4-4-4-12`.
- **The `$` is inside the quantifier** — `{12$}`. Go does *not* panic on this; it treats the
  brace as a **literal**, so the pattern compiles cleanly and matches nothing.

Together these make `looksLikeManagedIdentity` **return false for every input**. The guard
he was asked to write does not guard. No panic, no error, no failing test — it is simply
inert.

**And nothing would have caught it**, because:

- the four existing tests were not run at the point of capture;
- no new test was written.

**What is credited.** Three of the "would not compile" items are the kind of thing an editor
fixes in ten seconds, and he was typing under observation with someone watching. Syntax
under pressure is cheap. **The regex defects are not**, and a single test against one real
GUID would have exposed both instantly.

**Corrections made to the original evaluation** (2026-08-21, verified):

- *"trailing comma → too many arguments"* — **wrong**, that is legal Go. Not counted here.
- *"`MustCompile` panics"* — **wrong**, and the reality is worse: it compiles and silently
  never matches.
- *"`regexp` and `strings` not imported"* — **unverifiable**, the import block is not in the
  captured artefact. Not counted here.

---

## 3. Architectural decisions — 12 / 25

**Sound instincts:**

- Extracted a **named predicate** (`looksLikeManagedIdentity`) rather than inlining the
  match. Correct instinct — it is the testable seam.
- **Anchored** the regex (`^…`), so it matches a whole value rather than a substring.
- Separated the **iteration** (`validateUIConfigVars`) from the **decision** (the predicate).
- An error message that explains the remedy, not just the fault.

**Costly choices:**

- **He wrote a second `Validate` rather than filling in the `TODO`.** It collides with the
  existing function and would fail all four existing tests. The rubric's "concerning" column
  is literally *"rewrites `Validate` in their own style"*. This is the most significant mark
  against him on this dimension, because it is about **working inside someone else's code**
  — which is most of the job at this level.
- **Passed `*[]error` by pointer** where the surrounding code returns `[]error`. Inventing a
  second convention alongside an existing one.
- **Regex compiled inside the function**, so it recompiles on every call. Minor, and the
  seniority signal is that it was not noticed.
- **The core rule is value-shape only**, with no key-name condition. This is *the* design
  decision in the exercise, and it is the one that produces the `VITE_AUTH_TENANT_ID` false
  positive. Choosing it deliberately and naming the trade-off would be fine; there is no
  record he did.
- `looksLikeManagedIdentity` — a **managed identity** is a different Azure construct from an
  app registration's client ID. Worth one question rather than a deduction, but at senior
  level the vocabulary is part of the design.

**A note for scoring, not against him.** Because the predicate is always-false (see §2), the
tenant-ID false positive **would never actually have fired**. He neither passes nor fails
that discriminator in code — it can only be judged on what he *said*, and that was not
recorded.

---

## 4. Effort — 15 / 25

The thinnest dimension. Stated plainly so nobody mistakes this for a measurement.

**For:**

- Substantial code produced in about an hour, under observation, in an unfamiliar codebase.
- Attempted the **scope-suffix** edge case without being prompted. That is discretionary
  effort — the exercise did not require it.
- Kept going and structured the solution rather than stalling.

**Against:**

- **Did not run the four existing tests.** They were there. Running them is one command and
  would have shown the collision with `Validate` immediately.
- **Wrote no tests**, in an exercise about writing a validator.
- Created a GitHub account **two minutes before the invite** because he could not access an
  existing one. Read charitably this is a logistics failure and may not be his; read less
  charitably it suggests he did not check his tooling beforehand. **We should not score this
  either way without knowing which** — and nobody asked.

**Why 15:** the positive signals are real but modest; the "did not run the tests" point is
the one that matters at senior level, because it is a habit rather than a skill.

---

## Recommendation

**Do not decide on this card alone.** Two things would change it materially, and both are
cheap:

1. **Recover his real `git diff`** from the codespace. Several §2 items are transcription
   artefacts and at least three have already proven to be wrong or unverifiable. If his
   actual file compiles, §2 moves substantially.
2. **Write down what he said** about criteria 1 and 2 while any recollection survives — and
   label it as a four-day-old recollection, not a contemporaneous note. If it cannot be
   reconstructed, then **criteria 1 and 4 must not be scored for the next candidate either**,
   or the comparison is rigged in the next person's favour.

**My read, holding those caveats:** the design instinct is that of a competent engineer —
the right seam, the right anchor, the right error message, and an unprompted reach for a
second value shape. The execution is well below senior: a guard that guards nothing, no
tests written, existing tests not run, and a new `Validate` bolted alongside the one he was
asked to complete. The gap between *shape* and *execution* is the whole story of this round.

**On the evidence available: hold, pending the real diff.** If the diff shows the same regex
defects and the same duplicate `Validate`, that is a decline for a senior role. If it shows a
compiling file with the tests run, this was a transcription artefact and he deserves a
second exercise.

---

## Scoring bands used — apply these unchanged to the next candidate

| Band | Meaning |
|---|---|
| 22–25 | Senior-strong. Would do this unsupervised and improve the surrounding code. |
| 17–21 | Meets the bar. Sound, with gaps a review would catch. |
| 12–16 | Below bar for senior, plausible at mid. Right instincts, unreliable execution. |
| 6–11 | Materially short. The output does not do what it claims to do. |
| 0–5 | Absent or fundamentally misdirected. |

# Mar Sanchez — marsanchez-del

- **Date:** 2026-08-17
- **Round:** Senior Platform Engineer, Exercise 01 only (~1 hour)
- **Interviewer:** Dare Oke
- **Code captured:** **partial** — screen-share transcription, not a `git diff`. See `submission/README.md`
- **GitHub account:** created 2026-08-17 17:38, two minutes before the invite (couldn't access an existing one)

---

## 1. Understands the problem — score _/4

**Interviewer's assessment during the round: "He did well with 1."**

Fill in his own words here — the quote is the evidence, and it's what makes this comparable
against the next candidate.

>

## 2. Designs a sound solution — score _/4

**The rule he reached for:** value-shape only. A GUID regex, plus a special case for a scope suffix.
No key-name condition at the point of capture.

Consequences of that design, as written:

- `VITE_AUTH_CLIENT_ID` — caught
- `VITE_TASK_API_SCOPES` — **missed**. He checks for `/default`; the real suffix is `/.default`
  (with a dot). One character
- `VITE_AUTH_TENANT_ID` — **false positive**. A tenant ID is a GUID, so a value-only rule flags it.
  This is the exercise's main discriminator

Did he spare `VITE_AUTH_TENANT_ID`? unprompted / after a hint / no →

Did he name the strict-versus-loose trade-off out loud? →

**Worth crediting regardless:** he anticipated the scope-suffix shape at all, which several
candidates won't. The instinct was right; the string was wrong.

## 3. Writes the code — score _/4

Against the transcription. **All of this is mechanical and objectively checkable** — it is not a
judgement call, and it should be re-checked against his real diff if one is recovered.

**Would not compile:**

- Three named `func` declarations nested inside `validateUI`. Go has no nested named functions
- `regexp.MustCompile(...)` called with a trailing comma → too many arguments
- `fmt.Errorf("ui.configVars". %s ...` — `.` where a `,` belongs, and a string literal broken
  across lines
- `func(s*Spec) Validate () []error` — malformed receiver, and it **redeclares** the `Validate`
  already in the file with a different signature
- `var errors []errors` — the package name used as a type; also shadows the imported `errors`
- `if s.UI! =nil` — `!=` split by a space
- `regexp` and `strings` not added to the import block

**Would panic at runtime even once it compiled:**

- Regex reads `{12$}` — the `$` is inside the quantifier. `MustCompile` panics on an invalid repeat
  count. This survives compilation and dies on first call

**Structural:**

- He wrote a **second `Validate`** rather than filling in the `TODO`. That collides with the
  existing function and would fail all four existing tests. The rubric's concerning column is
  literally "rewrites `Validate` in their own style"
- Passes `*[]error` by pointer instead of returning `[]error` as the surrounding code does
- Regex declared inside the function, so it recompiles on every call
- `looksLikeManagedIdentity` — "managed identity" is a different Azure concept from an app
  registration's client ID. Naming worth one question, not a mark against
- Existing four tests: not run at the point of capture
- No new tests written

**In his favour:** the shape of the solution — a predicate helper, an anchored regex, a loop over
`configVars`, an error message that explains what to do instead — is the right shape. He had the
design in his head and lost the round to syntax.

---

## Overall

**One thing I'd want on the team:**

**One thing that would worry me in week one:**

**Recommendation:** advance to 02-05 / hold / decline

---

## Notes for the comparison

Two things to hold steady when scoring the next candidate against this one:

1. **He is being judged on a partial transcription.** If the next candidate submits a clean `git
   diff`, that is a fairer artefact and the comparison is not like-for-like. Weight accordingly, or
   go back and recover his real file
2. **The format was Exercise 01 alone.** Criteria 1 and 2 were assessed by conversation, not by
   anything he produced. Whatever he said needs writing down here while it is fresh — by tomorrow
   the only durable evidence will be the code, and the code is the weakest of the three

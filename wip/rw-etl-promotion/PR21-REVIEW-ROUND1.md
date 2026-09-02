# PR #21 — variant-inc/risingwave-pipeline — Round 1

**"fix: harden pipeline apply routing and configuration"** · `ifagbemi-usxpress`
Branch `fix/INFRA-1675-guardrail-routing-account-ids` -> `master` · commit `7fd05d7`
**+90 / -32 across 5 files** · 6 checks green · review requested from `dare-x`
Reviewed 2026-09-02 by Dare Oke. **Round 1 is from the PR page only — the diff has not
been read.** Every finding below is framed as a question for that reason; nothing here
asserts a defect in code I have not seen.

## Verdict

**Do not approve yet.** One of the five architecture blockers is fixed in code, four are
honestly deferred to a follow-up list, one is unacknowledged, and the PR itself introduces
a placeholder into a production overlay.

## Blocker traceability

Against `REVIEW-IDRIS-ARCHITECTURE-2026-09-02.md`.

| # | Blocker | Status in PR #21 |
|---|---|---|
| 1 | Secret records are Terraform's; `entity-postgres` / `mongodb` absent | **Deferred, named** — "Create missing Terraform-owned entity-postgres and optional mongodb records through Octopus TfApply". Correct mechanism named. |
| 2 | Flux owns `risingwave`, Argo owns `app-risingwave` | **Deferred, named** — "Create the dev Argo CD Application while preserving Flux ownership of the RisingWave platform namespace". The boundary is stated. |
| 3 | ESO green is not a content check | **FIXED IN CODE** — "missing or empty variables fail before database connections". Right control, right place. Verify it fires. |
| 4 | Rollback undefined; the design is forward-only | **NOT ACKNOWLEDGED.** Absent from the diff and from the follow-up list. The only one of five with no disposition. |
| 5 | `pipeline_applied` is a single point of replay | **Deferred, named** — "Define backup and restore handling for pipeline_applied". |

Advisory 1 (name the dev namespace) and advisory 4 (Brand Avro schema-registry keys) are
both on the follow-up list. Advisory 2 (`PIPELINE_DIR` vs `EXCLUDE_RE`) is **converged** —
he kept `/pipeline/pipelines` as the stable root and added `EXCLUDE_RE`, which is the
option this review argued for.

## Findings

### 1. BLOCKER — a placeholder digest is being merged into the production overlay

His own follow-up list: *"Replace the production placeholder digest through the normal
promotion flow."* So `master` would carry a production overlay pointing at an image
reference that does not resolve.

This is the shape that broke op-usxpress-prod on 2026-09-01: `PLACEHOLDER_INJECT_REAL_LICENSE`
synced green, the console rejected it, and it crashlooped a second Job with nothing to do
with licensing. A placeholder is only inert while nothing reconciles it — and creating the
Argo Application that would reconcile it is item 3 on the same list.

**Ask:** either land the prod overlay with a real digest, or split the prod overlay out of
this PR and keep it unmerged until promotion supplies one. If it must merge, the overlay
needs something that fails loudly rather than resolving to a pullable-but-wrong image.

### 2. BLOCKER — two overlays changed, neither rendered

*"Kustomize rendering was not run because it is unavailable in the current environment."*
Six checks passed. Those two facts are only compatible if the checks do not render overlays.

An unrendered overlay change is the cheapest possible thing to validate and the easiest
to get wrong — this is the adjacent-green-signal family: a true green about the step next
to the one that matters.

**Ask:** paste `kustomize build` output for both overlays, and say whether any of the six
checks renders them. If none does, that is a CI gap worth its own ticket.

### 3. BLOCKER — rollback is still undefined

`pipeline_applied` records each file's SHA-256, skips unchanged files and refuses changed
ones. Reverting the overlay to a previous digest therefore gives the old container pointed
at a RisingWave that already carries the new objects. Nothing in this PR or its follow-up
list says the pipeline is forward-only or what recovery is.

**Ask:** state forward-only explicitly, and give the break-glass path for the objects a bad
apply created — noting the CI guardrail blocks `DROP`, which is the tension that needs a
named approver.

### 4. ADVISORY — `bash -n` does not test the validation

`bash -n build/apply.sh` proves the file parses. The claim is behavioural: a missing or
empty variable must fail *before* any database connection.

**Ask:** run the script once with a required variable unset and once with it set to the
empty string, and show a non-zero exit with the variable named in both. Empty-string is the
case that gets missed — `[ -z "$X" ]` and `[ -v X ]` are different tests, and ESO's failure
mode from finding 3 produces an **absent key**, which becomes an empty variable, not an
unset one.

## Still to do

Round 2 needs `gh pr diff 21 --repo variant-inc/risingwave-pipeline`. Specifically:

- Does the validation run before the first `psql` / connection call, or after it?
- Does `EXCLUDE_RE` anchor its matches? An unanchored regex excluding `employee` also
  excludes anything containing that substring.
- Do the QA and prod exclusion lists agree, and does prod exclude anything QA does not?
- Does the `%VARIABLE%` renderer fail on an unresolved placeholder, or emit it literally
  into SQL?
- `.gitignore`: which paths, and does anything already tracked become ignored?

## Proven

- PR #21 is +90/-32 over 5 files on commit `7fd05d7`, targeting `master` — 2026-09-02.
- The architecture and presentation documents are **gitignored**, so the four documentation
  blockers are not answered in this repo; they are answered in the PR body's follow-up list.
- Advisory 2 converged on `EXCLUDE_RE` with `/pipeline/pipelines` as the stable root.

## Tested and killed

- The earlier read that "four blockers were answered into gitignored files" — **wrong**.
  The file count (5) and the PR body show he did not claim to have fixed them at all; he
  listed them as rollout prerequisites, which is the honest disposition. Corrected here
  rather than deleted because the description alone did read that way.

## Traps

- Six green checks on a PR whose author states the overlays were never rendered. Green
  covers what it covers.
- A placeholder in a prod overlay is inert exactly until someone completes the follow-up
  item that makes it live.
- `bash -n` on a script whose whole point is a runtime assertion.

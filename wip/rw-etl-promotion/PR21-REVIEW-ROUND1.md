# PR #21 — variant-inc/risingwave-pipeline — Round 1

**"fix: harden pipeline apply routing and configuration"** · `ifagbemi-usxpress`
Branch `fix/INFRA-1675-guardrail-routing-account-ids` -> `master`
Commit `7fd05d73c6f4faff7e25cb97386a16c9a9e29e29` · MERGEABLE · 6 checks green
**+90 / -32 across 5 files** · reviewed 2026-09-02 by Dare Oke, **full diff read**

Files: `.gitignore` (+7/-1), `README.md` (+8/-0), `build/apply.sh` (+71/-29),
`deploy/overlays/prod/endpoints.yaml` (+2/-1), `deploy/overlays/qa/endpoints.yaml` (+2/-1).

## Verdict

**Do not approve as one PR.** The `apply.sh` hardening is good work and fixes the blocker it
set out to fix. But the two overlay files silently perform the **first real cutover** —
`/pipeline/smoke` to `/pipeline/pipelines` on QA *and* prod — and `apply.sh` has one
correctness defect that the cutover would expose.

Split it: merge the script hardening, hold the overlays.

## Blocker traceability

Against `REVIEW-IDRIS-ARCHITECTURE-2026-09-02.md`.

| # | Blocker | Status |
|---|---|---|
| 1 | Secret records are Terraform's; `entity-postgres` / `mongodb` absent | Deferred, correct mechanism named (Octopus TfApply) |
| 2 | Flux owns `risingwave`, Argo owns `app-risingwave` | Deferred, boundary stated in the follow-up list |
| 3 | ESO green is not a content check | **FIXED — verified in the diff.** See below. |
| 4 | Rollback undefined; forward-only | **Still unacknowledged.** Not in the diff, not in the follow-up list. |
| 5 | `pipeline_applied` replay after a metastore restore | Deferred, named |

Advisory 2 (`PIPELINE_DIR` vs `EXCLUDE_RE`) **converged** on the option this review argued
for: `/pipeline/pipelines` as the stable root with exclusions carried in the overlay.

### Blocker 3 — confirmed fixed, by reading the order of operations

The `pg -q <<SQL CREATE TABLE pipeline_applied` block was **moved** from before the file
scan to after the missing-variable check. Nothing opens a connection until validation has
passed. The `RW_HOST="${RW_HOST:?...}"` fail-fast was deliberately replaced by
`"${RW_HOST:-}"` plus collected validation, which reports every missing variable at once
instead of dying on the first — a better failure. Both the unset and empty-string cases are
covered: `[ -z "${!var:-}" ]` catches both, and the `%VAR%` scan additionally uses
`[ -z "${!var+x}" ]`.

This is the right control in the right place, and it is the one of the five that needed code.

## Findings

### 1. BLOCKER — this PR performs the first real cutover, on QA and prod, in one commit

```diff
-  PIPELINE_DIR: /pipeline/smoke        # switch to /pipeline/pipelines/Brand for the real run
+  PIPELINE_DIR: /pipeline/pipelines
```

Identical in `deploy/overlays/qa/endpoints.yaml` and `deploy/overlays/prod/endpoints.yaml`.

Until this commit both environments ran the smoke payload — that is what "the path is proven
on QA" has meant since 2026-08-20. This changes what actually executes against RisingWave in
production, and it arrives inside a PR whose title, body and four other files are about
hardening a script.

The change may well be right. It is not right *here*, and not on both environments at once.

**Ask:** split the overlays into their own PR, QA first, with the cutover named in the title.

### 2. BLOCKER — the exclusion set is narrower than the one we agreed

```
(^|/)(employee|secret_manager|Template|shared/scripts)(/|$)|^pipelines/Brand/300-transform\.sql$
```

The regex construction is **correct** — anchored on both sides by `(^|/)` and `(/|$)`, so no
substring leakage, and the single-file alternative is fully anchored against
`rel="${f#/pipeline/}"`. That is better than most exclusion lists survive.

The *contents* are the problem. On 2026-08-26 the held-back set was seven entries:
`Template`, `scripts`, `900-user-access`, `employee`, `secret_manager`,
`001-secrets-mongodb`, `400-sink`. Three are absent here: **`900-user-access`,
`001-secrets-mongodb`, `400-sink`**. Either those directories no longer exist, or they are
now in scope for a production apply.

`shared/scripts` also replaced a bare `scripts`, which is a narrowing if `scripts` appears at
any other depth.

`300-transform.sql` is excluded by exact path with no reason recorded anywhere.

**Ask:** list every directory under `pipelines/` and mark each in-scope or excluded with a
reason. An exclusion list is a decision record; three silently dropped entries is the same
class as a stale copied manifest.

### 3. BLOCKER — the tracking-table hash is of the template, not the rendered SQL

Rendering is new in this PR:

```bash
rendered_content=$(<"$f")
while IFS= read -r token; do
  var="${token:1:${#token}-2}"
  rendered_content="${rendered_content//"$token"/${!var}}"
done < <(grep -oE '%[A-Z][A-Z0-9_]*%' "$f" | sort -u)
```

`$sha` is computed from `$f` **before** this runs — it must be, because the skip decision
happens above the `DRY_RUN` line and rendering happens below it. So `pipeline_applied` stores
the hash of the unrendered template.

Consequence: change a `%VARIABLE%` value in the ConfigMap or the Secret, re-sync, and the
file's sha is identical. The file is **skipped**. The new value is never applied, and the Job
reports success. Rendering was added without updating the key that decides whether to apply.

This is the silent-no-op family — the same shape as the `.replace()` that left a stale claim
in the capacity briefing, and the ESO sync that reported green over a placeholder.

**Ask:** hash the rendered content, not the file. One line, and it makes a variable change a
real change.

Confirm the current behaviour with:

```bash
sed -n '105,130p' build/apply.sh
```

### 4. BLOCKER — excluding everything succeeds

```bash
files=("${selected[@]}")
if [ ${#files[@]} -eq 0 ]; then echo "no .sql or .rw files under ${PIPELINE_DIR}"; exit 0; fi
```

The empty check used to mean "the directory is empty". It now also means "the regex matched
every file", and it still `exit 0`s with a message asserting the directory is empty.

A typo in `EXCLUDE_RE` — an unescaped `.`, a stray `|` producing an empty alternative that
matches everything — is a Job that applies nothing, says the directory is empty, and turns
the Argo sync green. Given finding 2 puts that regex under active editing, this matters.

**Ask:** count before and after, and fail when the pre-exclusion set was non-empty and the
post-exclusion set is not. "Everything was excluded" is a configuration error, not a no-op.

### 5. ADVISORY — the README links two files this PR gitignores

`README.md` gains:

```
see [PIPELINE_ARCHITECTURE.md](PIPELINE_ARCHITECTURE.md)
see [IMPLEMENTATION_CHECKLIST.md](IMPLEMENTATION_CHECKLIST.md)
```

`.gitignore` gains, in the same commit:

```
/IMPLEMENTATION_CHECKLIST.md
/PIPELINE_ARCHITECTURE.md
```

Two links on `master` that resolve to nothing for everyone except the author. If the
documents are the answer to blockers 1, 2 and 5, they need to be in the repo; if they are
scratch, the README should not point at them.

### 6. ADVISORY — rendered values are substituted into SQL unescaped

`${rendered_content//"$token"/${!var}}` puts the raw value into the SQL text. Values come
from Secrets Manager via ESO, so this is not untrusted input — but a password containing a
quote produces a syntax error at best and a malformed statement at worst, and the failure
would be attributed to the SQL file rather than the credential.

Low priority given the source is trusted. Worth a note in the file.

### 7. LINT — `.gitignore` has no trailing newline

`+/build/create_architecture_ppt.py` then `\ No newline at end of file`. The next appended
entry concatenates onto that line.

## Proven

- Validation precedes every database connection on `7fd05d7` — the `CREATE TABLE` block was
  moved below the missing-variable check. Read from the diff, 2026-09-02.
- The `EXCLUDE_RE` regex is correctly anchored and matches against a `/pipeline/`-relative
  path. No substring leakage.
- Both QA and prod overlays move from `/pipeline/smoke` to `/pipeline/pipelines` in this
  commit.
- The PR contains **no digest change**. `+90/-32` over five files, none of which is a
  kustomization or image reference.

## Tested and killed

- **"A placeholder digest is being merged into the production overlay"** — **wrong**, and
  raised as a blocker in the first pass of this review. It came from the PR body's follow-up
  item "Replace the production placeholder digest through the normal promotion flow", which
  describes work *not in this PR*. The diff touches no digest. Corrected here rather than
  deleted: reading a follow-up list as a change list is exactly the mistake that a review
  from the PR page alone invites.
- **"Four blockers were answered into gitignored files"** — also wrong, from the same first
  pass. The PR body lists them as rollout prerequisites, which is the honest disposition.
  The gitignored documents are real, but they are additional, not a substitute.
- **"Two overlays changed and kustomize was never rendered" as a blocker** — downgraded. The
  overlay change is two ConfigMap keys; rendering would have caught nothing here. The CI gap
  is still worth a ticket, but it does not hold this PR.

## Traps

- A cutover can arrive as two lines inside a refactor. `PIPELINE_DIR` is one key in a
  ConfigMap and it decides what runs against production.
- Adding a rendering step silently invalidates any content hash taken before it.
- "No files found" and "every file was excluded" are different events with the same message
  and the same exit code.
- Six green checks on a PR that changes what executes in production. The checks cover the
  script, not the decision.

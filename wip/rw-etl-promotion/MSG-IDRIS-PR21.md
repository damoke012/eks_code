Round 1 on 7fd05d7 — full diff read.

The apply.sh work is good and it fixes the blocker it set out to fix. I checked the order
rather than taking the description: the CREATE TABLE pipeline_applied block moved below the
missing-variable check, so nothing opens a connection until validation passes. Replacing the
:? fail-fast with collected validation is a better failure too — you get every missing
variable at once instead of one per run. And EXCLUDE_RE with /pipeline/pipelines as the
stable root is the option I argued for; the regex is properly anchored on both sides, which
is the part these usually get wrong.

I am not approving it as one PR, for one reason above all the others.

1. This PR performs the first real cutover, on QA and prod, in the same commit.

   PIPELINE_DIR: /pipeline/smoke  ->  /pipeline/pipelines

   in both overlays. Until now both environments have been running the smoke payload — that
   is what "the path is proven on QA" has meant since 20 August. This changes what actually
   executes against RisingWave in production, and it arrives inside a PR whose title, body
   and other three files are about hardening a script.

   The change may well be right. Please split the two overlay files into their own PR, QA
   first, with the cutover named in the title. I will review that one on its own terms.

2. The exclusion set is narrower than the one we agreed on 26 August. That list had seven
   entries; this has four plus one file. Missing: 900-user-access, 001-secrets-mongodb,
   400-sink. Also `shared/scripts` where we had a bare `scripts`. Either those directories
   are gone, or they are now in scope for a production apply — and 300-transform.sql is
   excluded by exact path with no reason recorded. Please list every directory under
   pipelines/ and mark each in scope or excluded with a reason. The exclusion list is a
   decision record; that is the whole argument for preferring it over PIPELINE_DIR.

3. pipeline_applied stores the hash of the template, not of the rendered SQL. The sha is
   taken from $f before the %VARIABLE% substitution runs. So changing a variable's value in
   the ConfigMap or the Secret leaves the file's sha identical, the file is skipped, the new
   value is never applied, and the Job goes green. Rendering is new in this PR and the key
   that decides whether to apply did not move with it. Hash the rendered content instead —
   one line, and it makes a variable change a real change.

4. Excluding everything exits 0. The empty check now sits after the exclusion loop and still
   prints "no .sql or .rw files under ${PIPELINE_DIR}". A typo in EXCLUDE_RE — an unescaped
   dot, a stray pipe producing an empty alternative — gives you a Job that applies nothing,
   claims the directory is empty and turns the sync green. Count before and after, and fail
   when the set was non-empty before exclusion and empty after. That is a configuration
   error, not a no-op, and finding 2 means that regex is going to be edited.

Two smaller ones. README now links PIPELINE_ARCHITECTURE.md and IMPLEMENTATION_CHECKLIST.md
and the same commit adds both to .gitignore — two links on master that resolve to nothing
for anyone but you. If those documents answer the secrets, Flux-boundary and backup items,
they belong in the repo. And .gitignore has no trailing newline, so the next entry appended
will join the last line.

Still outstanding from the architecture review, and not in the diff or the follow-up list:
rollback. The pipeline is forward-only — pipeline_applied refuses changed files, so reverting
to a previous digest gives the old container pointed at a RisingWave that already carries the
new objects. Say that plainly somewhere, and give the break-glass path for objects a bad
apply created, noting the CI guardrail blocks DROP.

Your follow-up list is honest and I would rather have it than a PR claiming more than it
does. Four of the five are on it with the right mechanisms named.

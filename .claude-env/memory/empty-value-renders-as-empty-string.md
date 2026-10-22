---
name: empty-value-renders-as-empty-string
description: The shipped RW apply.sh has NO placeholder validation; set -u catches an UNSET value but an EMPTY one substitutes silently and is recorded as applied
metadata:
  type: project
---

`iaac-risingwave-cicd/build/apply.sh` (the SHIPPED applier, 225 lines) renders `%NAME%`
placeholders with a bare indirect expansion and no validation at all:

    rendered_content="${rendered_content//"$token"/${!var}}"

- **unset** ⇒ `set -u` fires: `line 181: FOO: unbound variable`, the whole run dies before
  anything applies. No file name, no key name — loud but useless as a diagnostic.
- **set but empty** ⇒ expands to `''` with **no error**. The DDL applies with an empty topic
  or credential, gets hashed, and is written to `pipeline_applied` as a success.

Combined with [[eso-writes-partial-secrets]] (a `SecretSyncedError` still writes the keys it
could resolve) this is a silent-wrong: broken DDL recorded green. When the real value later
arrives the hash changes, so an environment with `REAPPLY_CHANGED=false` then REFUSES it
forever.

Also: the token regex is `%[A-Z][A-Z0-9_]*%` — one char minimum — so SQL `LIKE '%ABC%'` is
parsed as a placeholder and aborts the run.

**Why:** two copies of `apply.sh` exist with *different architectures*. The draft in
`eks_code/wip/onprem-app-cicd/reapply/apply.sh` has a `render()` function with a real
`missing`/`UNRESOLVED` validator; the shipped copy has no such function. Notes written from
the draft asserted "apply.sh rejects a missing OR empty value" — half wrong, and the wrong
half was the dangerous one.

**How to apply:** check secret values for **emptiness**, never just `Ready` or key count,
before un-excluding a path or enabling a pipeline. Read the shipped file by line number
before quoting applier behaviour — see [[edited-copy-is-not-the-shipped-copy]]. And when a
grep for a guard's name misses, consider that the guard does not exist rather than that it is
spelled differently: [[proxy-is-not-the-property]].

## ✅ CORRECTED 2026-10-21 — the shipped script NOW validates

Measured from a real failure on op-dev (`app-risingwave/etl-pipeline-apply`):

    loading pipeline config: /pipeline/pipelines/config/dev.env
      selected 17 of 23 discovered, excluded 6
    ERROR: required runtime values are missing or empty: MONGODB_HOST,MONGODB_PASSWORD MONGODB_PORT,MONGODB_USERNAME

It **aborted on empty** rather than substituting blanks and recording green — the behaviour
this note was written to warn about. The applier image pinned by digest
`sha256:e7dbbb30…` carries it, built 2026-10-14 09:31, one minute after
`fix(apply): port per-env config sourcing and re-apply into the shipped script`.

**The warning still applies to any OLDER applier digest**, and the image is pinned per
consumer — so check which digest a repo pins before assuming it validates.

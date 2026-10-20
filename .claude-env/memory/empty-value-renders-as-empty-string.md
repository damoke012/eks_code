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

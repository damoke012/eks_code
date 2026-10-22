---
name: validator-checks-every-value-not-the-selected-ones
description: "apply.sh validates ALL runtime values before it selects which files to run, so a variable needed only by an excluded file still fails the whole run — a deliberate blank 'to fail loudly' fails the wrong thing"
metadata:
  type: feedback
---

**2026-10-08, op-usxpress-dev, the ETL applier's first run.** I set
`KAFKA_SCHEMA_REGISTRY_MESSAGE: ""` on purpose — a blank fails loudly where a placeholder
like `unknown` or `abc123` passes a non-empty check and then fails inside RisingWave at
decode time — and put `/Brand/` in `EXCLUDE_RE` so nothing would need it.

Both halves were right. The conclusion was wrong:

    ERROR: required runtime values are missing or empty: KAFKA_SCHEMA_REGISTRY_MESSAGE

`build/apply.sh` validates **every** runtime value up front, *before* it applies
`PIPELINE_DIR` and `EXCLUDE_RE`. Excluding a file does not exclude its variables. So the
blank failed the entire run — including the files that had nothing to do with Brand — and
the deliberate loud failure landed on the wrong subject.

**How to apply.** "Exclude the feature, blank its config" is not a safe pairing against a
validator that runs before selection. Either supply a real value for an excluded feature (it
is unused, so even a wrong one cannot fail at use time), or confirm the validator is
selection-aware first. Read the validator, do not infer it from the exclusion mechanism
existing.

The fix on dev was to copy QA's real value while keeping `/Brand/` excluded: the validator
passes, nothing consumes the value, and it still must be verified against
`dev_brand_management_cdc_brand_avro-value` before Brand is included.

Related: [[config-can-outrun-the-image]], [[merged-defect-authorizes-itself]].

## ✅ 2026-10-09 — the lever is PIPELINE_DIR, not EXCLUDE_RE

Pointing dev at Tim's image failed with **27** missing runtime values at once:
`GROUP_ID_PREFIX`, nine more `KAFKA_*`, eight `MONGODB_*`, nine `POSTGRES_*`.

Almost none were needed. `POSTGRES_ENTITY_*` appear **only** in
`pipelines/shared/scripts/db-init/000-init-db-entities.sh` — a file `EXCLUDE_RE` already
excludes, and whose `_EMPLOYEE` lines are commented out. The validator demanded credentials
for a file it would never run.

**Widening EXCLUDE_RE cannot fix this, because validation happens first.** The fix is to
narrow **discovery**: `PIPELINE_DIR: /pipeline/pipelines/100-Brand` meant only Brand's files
were found, so only Brand's variables were required — nine, all of them already in
`op-usxpress-dev/risingwave/kafka`.

**How to apply:** map the variables per file before supplying any of them —

    for f in $(find pipelines -type f \( -name '*.rw' -o -name '*.sql' \) | sort); do
      V=$(grep -oE '%[A-Z_]+%' "$f" | tr -d '%' | sort -u | tr '\n' ' ')
      printf '%-46s %s\n' "$f" "$V"
    done

That turned "27 values and two missing systems" into "nine values we already hold". Reach for
it before standing anything up: the error names every variable in the union, which reads as a
far bigger dependency than the subset you intend to run.

## ⚠️ CORRECTION 2026-10-09 (later the same evening) — exclusions ARE respected

The section above is **wrong about the mechanism**, and I wrote it the same night.

`apply.sh` validates only the files that survive `EXCLUDE_RE`. Proof from our own runs on
op-dev: after `PIPELINE_DIR` was widened back to `/pipeline/pipelines` with `400-sink.rw` and
`999-downstream_sinks.rw` excluded by basename, the apply **succeeded with no `MONGODB_*`
variable supplied at all**. If validation preceded exclusion, those eight would still have
been demanded.

**The real cause of the 27-value error was a regex that matched nothing.** The old
`EXCLUDE_RE` named `Brand/400-sink.rw` and the lowercase segment `employee`, while his tree
is `100-Brand/` and `300-Employee/` — capital E, numeric prefixes. Every exclusion silently
matched zero files, so every file was discovered and every variable required.

So the lever is **an `EXCLUDE_RE` that matches the real paths**, not `PIPELINE_DIR`. Narrowing
discovery worked, but it was a bigger hammer than needed and it stopped the other pipelines
being applied as a side effect.

**How to apply:** when a variable list looks far too long, first check whether the exclusions
match anything — print the `exclude` lines from the log and count them against the tree. A
renamed directory turns an exclusion into a no-op with no error anywhere, and the symptom is
a demand for credentials to systems you do not have. Same family as
[[a-guard-can-measure-the-wrong-thing]]: suspect the pattern before the system.

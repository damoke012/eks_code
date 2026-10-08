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

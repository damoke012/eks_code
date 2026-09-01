---
name: octopus-release-freezes-variables
description: An Octopus release snapshots project variables at creation; fixing a variable never reaches an existing release until the snapshot is refreshed
metadata:
  type: project
---

An Octopus **release freezes the project's variables at creation time**. Correcting a
project variable afterwards does nothing to a release that already exists — redeploying
that release keeps using the frozen value, and the task log prints the stale value with
no indication a newer one exists.

Refresh it (the "Update Variables" button) or the fix is invisible:

```bash
python3 scripts/octopus-release-snapshot-vars.py iaac-risingwave-onprem 0.5.6 --apply
```

`scripts/octopus-arm-tfapply.py` does the refresh as part of arming, and aborts if the
snapshot id does not move.

**Why:** on 2026-09-01 this cost two identical prod deploy failures after the wrong state
bucket was already corrected — the log kept showing QA's bucket, which read as "the fix
didn't apply" rather than "the release is holding an older copy".

**How to apply:** after changing any Octopus variable, either create a new release or
refresh the existing one's snapshot, then verify by reading the value back **out of the
snapshot**, not the project. Same shape as [[pod-env-secret-resolution]] — a value
resolved once at creation and replayed afterwards. See [[octopus-green-but-no-apply]],
[[terraform-state-bucket-is-per-account]].

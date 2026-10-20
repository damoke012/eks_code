---
name: delivery-is-a-relay-of-nine-gates
description: "App repo to on-prem Argo CD is NINE handoffs and all nine fail green; walk them in order, judge at the destination — skill onprem-app-wireup, check scripts/onprem-app-wireup-check.sh"
metadata:
  node_type: memory
  type: project
---

**2026-10-09, op-usxpress-dev.** Getting one application's SQL from a developer's repo into
an on-prem cluster took three weeks. **Nine handoffs, every one broken, every one reporting
success.** Eight green ticks and zero rows.

No individual fix was hard. **Identifying which of nine silent gates had failed was the
entire cost**, and each gate's symptom impersonates the next gate's cause.

The gates, the procedure and the commands: **`.claude/skills/onprem-app-wireup`**.
The read-only check: **`bash scripts/onprem-app-wireup-check.sh dev|qa|prod`**.
The full account: `wip/onprem-app-cicd/RUNBOOK-app-wireup.md`.

## The two that nobody looks for

1. **Nothing copies the digest into the environment's values file.** The app repo pushes an
   image; Argo CD watches the *platform* repo. With no step between them, Argo is correct to
   do nothing and every status upstream is green. This was being done by hand without anyone
   noticing it was a step. Fixed by `promote.yml` — a platform-side workflow that polls the
   registry and opens the promotion PR *there*, so the app repo needs no write access.
2. **An exclusion regex that matches nothing.** Ours named `Brand/` and lowercase `employee`
   while the tree was `100-Brand/` and `300-Employee/`. Every exclusion matched zero files,
   every file was discovered, and the run demanded 27 variables including systems we do not
   have. The error reads as a missing-credentials problem.

## How to apply

**Judge the relay at the destination.** Rows in the target table, and — because a row count
cannot prove an apply ran — **an object the new code renames**. Drop-and-recreate SQL rebuilds
to the same numbers from the same source: `brand_mv_raw=9` was recorded on 2026-08-28 and
again on 2026-10-09, so the count proved nothing. `brand_source_kafka` existing proved
everything.

Walk the gates **in order** and stop at the first red one. A later gate's reading is
meaningless while an earlier one is broken.

## Wrong beliefs this corrected

- *A failed file is marked applied.* No — `applied 0, skipped 10` meant another runner had
  done the work. **A skip is not evidence a file failed.**
- *Credentials are missing from the secret store.* They were present and never **wired**.
  Enumerate both ends before concluding absence; then check the credential's **shape** — a
  connection string and a host+port pair are not interchangeable.
- *The promotion PR lost a race against the required checks.* No PR existed; the image
  post-dated the last cron.

Related: [[ecr-repo-policy-is-per-repository]], [[two-orgs-join-at-ecr-not-github]],
[[validator-checks-every-value-not-the-selected-ones]], [[eso-writes-partial-secrets]],
[[hook-job-failure-destroys-its-own-log]], [[adjacent-step-green-signals]],
[[missing-credential-may-mean-missing-system]], [[psql-c-does-not-interpolate]],
[[risingwave-mongodb-sink-facts]].

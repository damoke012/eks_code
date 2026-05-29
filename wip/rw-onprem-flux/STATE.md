# RW on-prem Flux wiring — STATE

**Owner:** Idris (Doke reviewing)
**Jira:** [INFRA-1487](https://usxpress.atlassian.net/browse/INFRA-1487)
**Goal:** Bring Tim's `risingwave` ns workload under Flux GitOps via `iaac-risingwave-onprem` repo. Removes drift risk from Idris's hand-applied state.

## Current state (2026-05-29)

- PR [#7](https://github.com/variant-inc/iaac-talos-flux-cluster/pull/7) on iaac-talos-flux-cluster — OPEN, MERGEABLE, reviewDecision=CHANGES_REQUESTED
- Latest commit `4bbd5ab` added resource patches + healthCheckExprs (2026-05-29 17:15 UTC)
- Review captured in [pr-7-review-2026-05-29.md](pr-7-review-2026-05-29.md) — 3 blockers + 1 data-loss-risk verify + coordination asks
- **Decision: REQUEST CHANGES, do not merge until fixes land**

## Blockers

1. Hardcoded postgres password in Git
2. stateStore S3 bucket replacement (data-loss risk if bucket mismatches live)
3. risingwave-operator version range (allows auto-bump)
4. Earlier May 28 review items — placeholder cleanup unconfirmed from diff

## Coordination

Per [[feedback_protect_rw_onprem_workload]]: Idris must branch-test against live cluster + Tim must acknowledge reconcile window before merge.

## Next

- Idris responds on PR with fixes / data-bucket confirmation
- Round 2 review (append to pr-7-review-2026-05-29.md)
- After merge: update [[rw-manifest-landscape-2026-05-28]] memory (Tim's RW now Flux-managed)

## Files in this folder

- [STATE.md](STATE.md) — this file
- [pr-7-review-2026-05-29.md](pr-7-review-2026-05-29.md) — Round 1 review

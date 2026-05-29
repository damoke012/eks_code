# RW on-prem Flux wiring — STATE

**Owner:** Idris (Doke reviewing)
**Jira:** [INFRA-1487](https://usxpress.atlassian.net/browse/INFRA-1487)
**Goal:** Bring Tim's `risingwave` ns workload under Flux GitOps via `iaac-risingwave-onprem` repo. Removes drift risk from Idris's hand-applied state.

## Current state (2026-05-29 PM, post-verification)

- PR [#7](https://github.com/variant-inc/iaac-talos-flux-cluster/pull/7) on iaac-talos-flux-cluster — OPEN, MERGEABLE, reviewDecision=CHANGES_REQUESTED
- Latest commit `4bbd5ab` (2026-05-29 17:15 UTC)
- **Round 1 comment**: [comment-4578051242](https://github.com/variant-inc/iaac-talos-flux-cluster/pull/7#issuecomment-4578051242)
- **Round 2 comment (post-verification)**: [comment-4578141644](https://github.com/variant-inc/iaac-talos-flux-cluster/pull/7#issuecomment-4578141644)
- Review captured in [pr-7-review-2026-05-29.md](pr-7-review-2026-05-29.md)
- **Decision: STILL REQUEST CHANGES** — 3 blockers remaining

## Blockers (current)

1. Hardcoded postgres password in Git — **OPEN** (Idris fixing)
2. ~~stateStore S3 bucket replacement~~ — ✅ **CLEARED** (independently verified, 4/4 fields + 107+ hummock prefixes)
3. risingwave-operator version range (allows auto-bump) — **OPEN** (Idris fixing)
4. ~~Placeholder comments in infra.yaml~~ — ✅ **CLEARED** (verified clean around line 513)
5. ~~metaStore catalog loss risk~~ — ✅ **CLEARED** (source CR matches live; both use `pg-postgresql`)
6. **RW secret key NOT wired to CR env** — **OPEN, PROMOTED TO BLOCKER** (carried from May 28 round; affects Tim's RW built-in secret manager)

## Advisories (not blockers but should resolve)

- A1: Dead `postgres` HR in source — `postgres-helmrelease.yaml` provisions a postgres nothing references. Resolve before merge OR commit to follow-up PR.
- A2: Legacy `pg-postgresql` (the one RW actually uses) not in source — long-term drift risk. Adoption needed in follow-up.
- Lint: trailing whitespace + missing EOF newline on `infra.yaml`.

## What we independently verified (kubectl + git clones)

- Live cluster: stateStore bucket, region, dataDirectory, useServiceAccount all match patch.
- Live cluster: compute pod resources already at patch values (no restart on merge).
- Live cluster: RW Running=True baseline.
- AWS: bucket `risingwave-state-op-usxpress-dev` has 107+ hummock prefixes.
- Source repo: RW CR points at `pg-postgresql` (matches live, no catalog rewire).
- Source repo: RW CR env block does NOT consume `RW_SECRET_STORE_PRIVATE_KEY_HEX`.
- Recent ns activity: 4h-old postgres + 3.5h-old meta/operator restart → Idris likely pre-deployed source manifests as branch test.

## Coordination still needed (per [[feedback_protect_rw_onprem_workload]])

- Idris to confirm branch test ran clean against live (pods stayed Running=True)
- Tim to acknowledge reconcile window

## Next

- Idris fixes Blockers 1, 3, 6 + addresses advisories
- Round 3 review on his next push (append to pr-7-review-2026-05-29.md)
- After merge: update [[rw-manifest-landscape-2026-05-28]] memory (Tim's RW now Flux-managed)

## Files in this folder

- [STATE.md](STATE.md) — this file
- [pr-7-review-2026-05-29.md](pr-7-review-2026-05-29.md) — Round 1 + Round 2 reviews

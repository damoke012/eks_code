# RW on-prem Flux wiring — STATE

**Owner:** Idris (Doke reviewing)
**Jira:** [INFRA-1487](https://usxpress.atlassian.net/browse/INFRA-1487)
**Goal:** Bring Tim's `risingwave` ns workload under Flux GitOps via `iaac-risingwave-onprem` repo. Removes drift risk from Idris's hand-applied state.

## Current state (2026-05-29, post-Round 3)

- PR [#7](https://github.com/variant-inc/iaac-talos-flux-cluster/pull/7) on iaac-talos-flux-cluster — OPEN, MERGEABLE, reviewDecision=CHANGES_REQUESTED
- Latest commit `d2dfdd5` — addresses all 3 remaining blockers
- **All 3 review rounds posted**:
  - Round 1: [comment-4578051242](https://github.com/variant-inc/iaac-talos-flux-cluster/pull/7#issuecomment-4578051242)
  - Round 2: [comment-4578141644](https://github.com/variant-inc/iaac-talos-flux-cluster/pull/7#issuecomment-4578141644)
  - Round 3: [comment-4578356999](https://github.com/variant-inc/iaac-talos-flux-cluster/pull/7#issuecomment-4578356999)
- Review captured in [pr-7-review-2026-05-29.md](pr-7-review-2026-05-29.md)
- **Decision: ALL CODE BLOCKERS CLEARED — Approve pending coordination**

## All blockers — final state

1. ~~Hardcoded postgres password~~ — ✅ FIXED in `d2dfdd5`
2. ~~stateStore S3 bucket~~ — ✅ CLEARED (independently verified Round 2)
3. ~~operator version range~~ — ✅ FIXED in `d2dfdd5` (pinned to `0.1.36`)
4. ~~Placeholder comments + EOF newline~~ — ✅ CLEARED
5. ~~metaStore catalog loss risk~~ — ✅ CLEARED (independently verified Round 2)
6. ~~RW secret key NOT wired to CR env~~ — ✅ FIXED in `d2dfdd5` (meta + frontend env patches, JSON paths verified)
7. ~~Compute resource patch restart concern~~ — ✅ NO RESTART (matches live)

## Advisories (not blockers, follow-ups)

- A1: Dead `postgres` HR in source — Idris has `POSTGRES_FOLLOWUP_PLAN.md` (gitignored). Asked him to put plan in PR comment or Jira sub-task for visibility.
- A2: Legacy `pg-postgresql` not in source — long-term drift risk on the postgres RW actually uses. Follow-up adoption needed.

## What remains before approve

Per [[feedback_protect_rw_onprem_workload]] applied to `risingwave` ns:

1. **Idris**: confirm branch test against live cluster (Tim's RW stayed Running=True end-to-end). Recent pod ages (postgres-postgresql 4h17m, meta 3h28m, operator 3h52m) suggest he already pre-applied. Need explicit confirmation of what he saw.
2. **Tim**: acknowledge reconcile window. Patches are no-ops on stateStore + compute; env additions on meta + frontend will restart those pods.

## Tim coord rule (locked in 2026-05-29)

| Target ns | Tim coord? |
|---|---|
| `risingwave` (Tim's) | ✅ Required |
| `risingwave-2` (Doke's IaC pattern) | ❌ Not required |
| Cluster-wide / platform with possible RW impact | ✅ Required ([[feedback_protect_rw_onprem_workload]]) |

Use namespace as trigger, not repo name. Verify via `grep -E "^\s*namespace:" manifests/...`.

## Next

- Wait for Idris's coordination responses
- On confirmations → approve + merge
- After merge: update [[rw-manifest-landscape-2026-05-28]] (Tim's RW becomes Flux-managed)
- After merge: address A1 (postgres HR cleanup) + A2 (pg-postgresql adoption) in follow-up PRs

## Files in this folder

- [STATE.md](STATE.md) — this file
- [pr-7-review-2026-05-29.md](pr-7-review-2026-05-29.md) — Rounds 1 + 2 + 3

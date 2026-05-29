# RW on-prem Flux wiring — STATE

**Owner:** Idris (Doke reviewing)
**Jira:** [INFRA-1487](https://usxpress.atlassian.net/browse/INFRA-1487)
**Goal:** Bring Tim's `risingwave` ns workload under Flux GitOps via `iaac-risingwave-onprem` repo. Removes drift risk from Idris's hand-applied state.

## Current state (2026-05-29, post-approval)

- PR [#7](https://github.com/variant-inc/iaac-talos-flux-cluster/pull/7) on iaac-talos-flux-cluster — **APPROVED 2026-05-29 PM**, awaiting Idris to merge
- Latest commit `d2dfdd5` — addressed all 3 remaining blockers
- **3 review rounds + approval**:
  - Round 1: [comment-4578051242](https://github.com/variant-inc/iaac-talos-flux-cluster/pull/7#issuecomment-4578051242)
  - Round 2: [comment-4578141644](https://github.com/variant-inc/iaac-talos-flux-cluster/pull/7#issuecomment-4578141644)
  - Round 3: [comment-4578356999](https://github.com/variant-inc/iaac-talos-flux-cluster/pull/7#issuecomment-4578356999)
  - Approval comment with merge guidance posted via `gh pr review --approve`
- Tim coord MET per Idris's Teams confirmation (Tim on his redhat server, not actively using cluster RW; aware of the changes)
- Review captured in [pr-7-review-2026-05-29.md](pr-7-review-2026-05-29.md)

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

## What remains

- Idris merges PR #7 (when he's ready)
- Post-merge: watch first Flux reconcile against live; confirm Tim's RW stays Running=True
- Post-merge: update [[rw-manifest-landscape-2026-05-28]] (Tim's RW now Flux-managed)
- Follow-up tickets needed for the 2 advisories (A1 + A2)

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

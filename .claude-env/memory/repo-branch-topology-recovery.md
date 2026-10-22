---
name: repo-branch-topology-recovery
description: Branch topology — main is now the consolidated canonical branch (fast-forwarded 2026-07-10 to contain all 120 commits)
metadata: 
  node_type: memory
  type: project
  originSessionId: 161fed6b-7af8-49e8-9abf-c06ed6494c28
---

**As of 2026-07-10, `main` is the canonical branch and contains everything** (120 commits). Earlier this repo was fragmented after a clone/recovery; that has been resolved.

- `main` (HEAD 4347524) — fast-forwarded on 2026-07-10 from `origin/transfer/rook-ceph-safe-reroll-jun17`; identical to it (0/0 divergence). Holds ALL work: QA stand-up, INFRA-1520 observability, RisingWave, on-prem networking/ingress, S3 CRR, Rook restore-readiness, MAN-242, enterprise IaC closeout. **Pushed to `origin/main`.**
- `recovered-work` (db30d3b, May 13) — the old thin lineage (RisingWave/networking docs only). Now a strict ancestor of `main`; superseded, kept for reference.
- `origin/transfer/rook-ceph-safe-reroll-jun17` — the historical source that `main` was built from; same tip as main.

**Repo layout** (reorganized during the June work): `docs/architecture/` (+ `historical/`), `docs/onboarding/idris-kt/`, `wip/<workstream>/`, `iaac-drafts/`, `archive/`. Root-level docs from the May lineage were moved into these — e.g. the RisingWave closeout is now `docs/architecture/historical/`, networking drafts are in `wip/onprem-networking/`.

**How to apply:** Work from `main`. Files are in the working tree — no need to inspect other branches. Related: [[qa-cluster-standup]], [[risingwave-onprem]], [[onprem-networking-ingress]].

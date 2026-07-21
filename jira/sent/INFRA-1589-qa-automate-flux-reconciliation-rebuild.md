# INFRA-1589: Automate QA platform-stack Flux reconciliation params + rebuild QA to validate

**Type**: Story
**Priority**: High
**Component**: On-prem / Talos / Flux
**Reporter**: Doke
**Epic**: INFRA-1560 (QA + production readiness)
**Labels**: qa-standup, INFRA-1585, platform, flux
**Created**: 2026-07-13

## Problem

The QA cluster (`op-usxpress-qa`) is stood up, but standing it up surfaced several platform-stack Flux **reconciliation parameters that had to be set manually**. Before we spin up the production cluster we want those automated so a cluster comes up from code with minimal manual steps.

## Scope

1. Identify every manual step / hand-set Flux reconciliation parameter from the QA build (platform stack: ESO, cert issuers, istio chain, external-dns, prometheus, grafana, etc.).
2. Parameterize / codify them in IaC (iaac-talos + iaac-talos-flux-platform op-qa).
3. **Rebuild the QA cluster from scratch** to prove the automation — near-zero manual intervention.
4. Do NOT retrofit to Dev (Dev stays as-is; this is forward to QA→Prod).

## Acceptance criteria

- Manual steps catalogued and codified.
- QA cluster rebuilt clean from code with the documented steps only.
- Runbook updated (`wip/qa-cluster-standup/`).
- Sign-off recorded that we're clear to spin up the prod cluster.

## Refs

- `wip/standup-2026-07-13/standup-extract.md` (T1)
- `wip/qa-cluster-standup/` (README + iaac-talos-refactor)

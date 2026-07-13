# INFRA-1596: Automate secret rotation — pod-scan + swap from Secrets Manager (future)

**Type**: Story
**Priority**: Low
**Component**: Identity / Secrets / Platform
**Reporter**: Doke
**Assignee**: Idris
**Labels**: secrets, automation, backlog
**Created**: 2026-07-13

## Problem

Secret rotation is currently manual. Idris proposed (2026-07-13 standup) automating it the same way as the on-prem flow: a job that scans pods/app secrets for near-expiry, removes the old, and pulls the new from Secrets Manager automatically — so rotation doesn't require manual intervention or downtime.

## Scope

1. Design a scanner (pod/app secret → expiry) + swap job.
2. Pull the new value from Secrets Manager; roll the workload safely.
3. Cover cloud + on-prem; align with the manual runbook (INFRA — secret rotation).

## Acceptance criteria

- Design doc + PoC on a lower env.
- Automated near-expiry detection + swap validated without downtime.

## Refs

- Depends on the manual rotation runbook landing first.
- memory: entra-secret-rotation (automation note)

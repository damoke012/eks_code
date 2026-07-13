# Pod crash-loop alerting (cloud + on-prem) via Grafana → FreshService

**Type**: Task
**Priority**: Medium
**Component**: Observability / Platform
**Reporter**: Doke
**Labels**: observability, alerting, freshservice, quick-win
**Created**: 2026-07-13

## Problem

Low-hanging first alert to prove the notification model: fire on pod crash-loop in both cloud (EKS) and on-prem (Talos) clusters, routed through FreshService (group → email). This is the "second leg" (notification/ticketing) of the alerting model that FreshService replaced PagerDuty for.

## Scope

1. Grafana alert rule for CrashLoopBackOff across cloud + on-prem.
2. Route via FreshService group→email integration (admin Josh Gilliland).
3. Document the pattern as the template for future platform alerts.

## Acceptance criteria

- CrashLoop alert firing on both clusters.
- Notification lands via FreshService group.
- Pattern documented.

## Refs

- `wip/standup-2026-07-13/standup-extract.md` (T5)

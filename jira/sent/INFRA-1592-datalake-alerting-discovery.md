# INFRA-1592: Data-lake alerting discovery — Kafka Connect + S3 (self-serve app-team guidance)

**Type**: Story
**Priority**: Medium
**Component**: Observability / Platform
**Reporter**: Doke
**Assignee**: Idris
**Labels**: observability, datalake, kafka-connect, s3, grafana, discovery
**Created**: 2026-07-13

## Problem

Nathaniel/Anthony's Confluent→S3 data-lake migration needs alerting for (a) failed Kafka Connect connectors and (b) stale S3 data (no new file in 24h / no topic message in 1h). Owned as platform discovery ("not on our budget" but platform-owned). Model = platform provides Grafana metrics + step-by-step guidance so **app teams create their own alerts**; platform does not build each app's alerts.

## Scope

1. Discovery doc: how to surface Kafka Connect connector-failure + S3 file-freshness metrics in Grafana (build the integration/metric where missing).
2. Step-by-step self-serve alert guide for app teams.
3. FreshService notification wiring plan (group → email; admin Josh Gilliland).
4. Link to their FreshService ticket + JIRA Epic "Confluent Cloud migration to S3 data lake."

## Acceptance criteria

- Discovery doc published.
- Grafana metric/integration approach validated.
- App-team self-serve alert guide.
- Notification path (FreshService) documented.

## Refs

- `wip/standup-2026-07-13/standup-extract.md` (T4)
- memory: datalake-kafka-s3-monitoring

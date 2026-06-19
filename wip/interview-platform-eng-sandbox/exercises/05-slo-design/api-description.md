# `shipment-tracking-api` — service description

Fictional service for SLO design exercise.

## Surface

- Public REST API behind an ALB → ingress-nginx → 12 pod replicas
- 3 main read endpoints: `GET /shipments`, `GET /shipments/{id}`, `GET /shipments/{id}/history`
- 1 write endpoint (internal-only, from the dispatcher service): `POST /shipments`

## Dependencies

- **Postgres (Aurora)** — primary store, read replicas in 3 AZs
- **Redis** — cache for hot shipment lookups (~85% hit rate)
- **Kafka** — emits `shipment_updated` events (fire-and-forget; failures here do not affect HTTP response)

## Traffic shape

- 200-2000 RPS, peaks at 4-5 PM ET
- 95% reads / 5% writes
- One endpoint dominates: `GET /shipments/{id}` at ~70% of total

## Latency today

- p50: 80ms
- p95: 250ms
- p99: 400ms

## Failure modes seen in the last quarter

- DB failover (RDS) → ~90s of 5xx during failover
- Cache cold-start after deploy → 2x p99 latency for ~5 min
- Kafka broker outage → 0 HTTP impact (good fire-and-forget design)
- Bad deploy with N+1 query → p99 jumped from 400ms → 8s

## On-call

- 2 engineers on rotation, 1-week shifts
- PagerDuty integration; secondary fires after 5 min unacked
- Customer-facing status page

## Customer expectations

- Customer contracts mention "99.9% availability" loosely
- Customers care most about: shipments visible within 5 min of dispatch creation
- Customers do NOT care if `/history` is slow

## What's NOT in scope for this exercise

- Authentication failures, rate limiting, billing
- Tracing setup (assume OTel + Tempo is wired)
- Logs (assume Loki is wired)

---

## Your notes / sketch (write below)

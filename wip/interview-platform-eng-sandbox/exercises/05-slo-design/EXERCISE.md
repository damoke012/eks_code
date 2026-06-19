# Exercise 05 — Design SLIs + SLOs + alerting for an API

**Time:** ~10 minutes (discussion + light writing)

## The service

`shipment-tracking-api` — a public-facing REST API used by ~30 customer-facing apps. Customers hit it 200-2000 RPS depending on time of day. P50 latency is 80ms; p99 is 400ms today.

[`api-description.md`](api-description.md) has the full picture: endpoints, dependencies, traffic shape, on-call rotation.

## Your task

In 10 minutes, propose:

1. **The SLI(s)** — what do you measure, where, and why?
2. **The SLO(s)** — what target(s), over what window, and why those numbers?
3. **The alert rules** — what alerts fire, at what thresholds, paging vs ticketing?
4. **The error budget policy** — what does the team do when budget is 50% / 80% / 100% consumed?
5. **What NOT to alert on** — what would you explicitly de-prioritize?

You can sketch in [`api-description.md`](api-description.md) or talk it through.

## What we're looking for

- You think about WHERE to measure and why your choice survives the worst failure modes
- You can justify your SLO target with concrete math — not just round numbers
- You distinguish "I'd want to know about this" from "wake someone up at 3am"
- You think about the policy side: when budget runs low, who decides what gives?
- You're explicit about what you'd NOT alert on, and why

Expect follow-up questions during — we'll dig into edge cases, what-ifs, and probe how you'd handle the messy realities.

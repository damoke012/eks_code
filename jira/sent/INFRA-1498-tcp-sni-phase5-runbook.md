---
key: INFRA-1498
status: filed
assignee: Doke
reporter: Doke
created: 2026-05-28
initiative: onprem-networking
labels: [onprem, networking, runbook, docs, phase5]
issuetype: Sub-task
parent: INFRA-1492
---

# Phase 5 — Operational runbook + onboarding checklist

## Context
Codify the per-service onboarding flow so app teams (and future on-call) can expose a new TCP service via this pattern without re-deriving the design each time.

## Scope

**In:**
- Runbook `docs/runbooks/tcp-sni-ingress-onboarding.md`: per-service checklist (Certificate manifest, Gateway/VirtualService snippet, backend chart values change, NP template, smoke tests).
- Rollback runbook: how to disable a single TLS-PT port without affecting others.
- Troubleshooting runbook: openssl s_client recipes, common SNI mismatches, cert-rotation incident procedure.
- SLO + monitoring outline: gateway pod availability, p99 TCP setup latency, cert expiry alerts.

**Out:**
- Implementation of monitoring/alerting (separate observability ticket).
- App-team self-service portal — runbook is the source for now.

## Definition of done
- [ ] Onboarding runbook published, reviewed by Steve / Vibin / Dare
- [ ] Rollback runbook published and tested (disable one port without disrupting others)
- [ ] Troubleshooting runbook covers the top-3 issues observed during Phases 1-4
- [ ] SLO doc drafted (acceptance: numbers may be initial estimates, refined post-launch)
- [ ] Link from `docs/runbooks/README.md` (or equivalent index)

## Constraints
- Runbook should be plain-English with code blocks. Per `feedback_automate_and_document`.
- Reference design doc for "why," not duplicate.

## Links
- Parent: [TCP/SNI ingress umbrella]
- Design doc: [`docs/designs/tcp-sni-ingress-design.md#phase-5`](https://github.com/damoke012/eks_code/blob/main/docs/designs/tcp-sni-ingress-design.md)

## Estimate
S — pure docs after Phases 0-4 land.

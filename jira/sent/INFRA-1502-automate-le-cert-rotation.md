---
key: INFRA-1502
status: filed
assignee: Doke
reporter: Doke
created: 2026-06-01
filed: 2026-06-01
initiative: onprem-networking
parent_link: INFRA-1492
---

# Automate Let's Encrypt cert rotation on op-usxpress-dev

## Context
Phase 0 cert-manager + LE PROD chain shipped 2026-05-28 ([INFRA-1493](https://usxpress.atlassian.net/browse/INFRA-1493)); wildcard `*.op-dev.usxpress.io` + per-team certs are valid through 2026-08-26 (~90 days). Steve Vives flagged manual rotation as the #1 ops risk in the 2026-05-29 networking/CySec call — "Mount Everest of expired certs". Doke committed to automating rotation. This ticket implements the cert-manager-driven hands-off renewal pipeline + sec sign-off gate before enabling.

Not a Phase 1 blocker, but required before QA promotion (per 2026-05-29 call).

## Scope

**In:**
- Verify cert-manager `renewBefore` is set on all existing Certificate resources (`wildcard-op-dev`, `brands-op-dev`, future per-team certs) — should be ~720h (30 days before expiry, default).
- Confirm Flux + cert-manager Renewal CronJob path is in place (cert-manager renews automatically on each reconcile when within renewBefore window — no extra wiring usually needed, but verify).
- Add a post-renewal hook / Alertmanager rule that emits a notification to Teams/Slack when a cert is renewed (visibility).
- Test automated renewal in dev by manually triggering an early renewal (`cmctl renew wildcard-op-dev`) and confirming the new Secret rotates without disruption to live workloads.
- Get Brendan + Steve Vives security sign-off before enabling notification path / treating as "production-grade rotation."

**Out:**
- Rotation alerting beyond renewal notification (covered by separate Prometheus cert-expiry alerting ticket — "Prometheus cert-expiry alerting").
- Changes to LE rate-limit budget tracking (not yet a concern).
- Manual fallback path (already exists; not removing it).

## Definition of done
- [ ] All Certificate resources on op-usxpress-dev have explicit `renewBefore: 720h` (or chart-default verified).
- [ ] One Certificate rotated successfully via `cmctl renew` in dev with no workload disruption (test on `wildcard-op-dev` or a sacrificial cert).
- [ ] Renewal event surfaced to Teams/Slack via Alertmanager hook.
- [ ] Brendan + Steve Vives signed off on the auto-rotation approach (PR comment or Teams).
- [ ] Runbook section added to `wip/onprem-networking/` describing rotation behavior + how to disable in emergency.

## Suggested approach
cert-manager already auto-renews when `renewBefore` is hit. The work is mostly verification + observability:
```bash
kubectl get certificate -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: renewBefore={.spec.renewBefore} expires={.status.notAfter}{"\n"}{end}'
cmctl renew -n istio-ingress wildcard-op-dev   # force early renew for the test
kubectl get certificate -n istio-ingress wildcard-op-dev -w
```
Add a PrometheusRule or Flux notification controller alert on `certmanager_certificate_ready_status` flips.

## Constraints
- No Octopus access required.
- Must NOT disrupt existing workloads — pre/post check RW Running=True per [[feedback_protect_rw_onprem_workload]].
- Brendan + Vives sec sign-off REQUIRED before declaring complete.

## Links
- Parent umbrella: [INFRA-1492](https://usxpress.atlassian.net/browse/INFRA-1492)
- Phase 0 closure: [INFRA-1493](https://usxpress.atlassian.net/browse/INFRA-1493)
- 2026-05-29 call review: `wip/onprem-networking/networking-call-review-may29.md`

## Estimate
M — verification + observability hook + sec sign-off coordination. ~half day focused.

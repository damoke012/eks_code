---
key: INFRA-1505
status: filed
assignee: Doke
co_assignee: Steve Vives
reporter: Doke
created: 2026-06-01
filed: 2026-06-01
initiative: onprem-networking
parent_link: INFRA-472
---

# Wiz eBPF onboarding for op-usxpress-dev (top-3 crown-jewel hosts)

## Context
Per the 2026-05-29 networking/CySec call, CySec is replacing Orca with Wiz across the org. Steve Vives (CySec, building Wiz out — ~1.5 weeks in at time of call) offered to drop the Wiz eBPF sensor on our top-3 on-prem crown-jewel hosts on op-usxpress-dev. This ticket onboards on-prem to the Wiz security telemetry plane, gives the team visibility into kernel-level activity on the most sensitive hosts, and sets up the operational pattern we'll scale to QA/PROD.

Co-owned with Steve Vives — Doke picks hosts + validates egress; Vives executes sensor install + tunes alerts.

## Scope

**In:**
- Pick top-3 crown-jewel hosts. Candidates: RisingWave compute host(s) (Tim's workload), Talos workers running platform pods, Octopus worker. Doke proposes; Vives reviews.
- Verify network egress from each chosen host to Wiz IO endpoints (sensor needs internet reach to wiz.io). If blocked, file firewall change request with Networking.
- Vives runs the sensor install (eBPF preload bootloader, runs on kernel).
- Walking session: Doke + Vives review the first 24h of telemetry; tune signal:noise.
- Document the onboarding pattern + alerting destination in `wip/onprem-networking/wiz-onboarding-runbook.md`.

**Out:**
- Cluster-wide rollout — top-3 first, expand based on telemetry quality.
- Wiz UI policies / custom detections — Vives owns; Doke consumes.
- Migration from Orca (Vives's separate workstream).
- Wiz "security gates" (admission control style) — separate ticket if pursued.

## Definition of done
- [ ] 3 host candidates documented + Vives sign-off
- [ ] Egress to wiz.io confirmed from each host (`curl` or equivalent) OR firewall ask filed
- [ ] Sensor running on all 3 hosts; status `healthy` in Wiz console
- [ ] First 24h of telemetry reviewed in Doke + Vives walking session
- [ ] Alert destination wired to team's Alertmanager/Teams channel
- [ ] Onboarding runbook committed to `wip/onprem-networking/`

## Suggested approach
Pick hosts:
```bash
# Find the worker hosting Tim's RW compute
kubectl get pods -n risingwave -l risingwave/component=compute -o wide
# Find the worker hosting RW-2
kubectl get pods -n risingwave-2 -l risingwave/component=compute -o wide
# Pick a third — likely a worker with cilium-operator or Octopus worker
```
Verify egress (run on host via debug pod or talosctl):
```bash
curl -v https://wiz.io 2>&1 | head -5
```

## Constraints
- No Octopus access required for the host selection / egress validation.
- Sensor install runs as Vives — Doke does NOT install (Wiz license / tenancy is CySec-owned).
- Must NOT disrupt Tim's workload — sensor is read-only kernel telemetry, should be transparent; pre/post check RW Running=True per [[feedback_protect_rw_onprem_workload]].

## Links
- Parent initiative: [INFRA-472](https://usxpress.atlassian.net/browse/INFRA-472)
- 2026-05-29 call review: `wip/onprem-networking/networking-call-review-may29.md`

## Estimate
M — host selection + egress validation + sensor install + walking session. ~half day across Doke + Vives.

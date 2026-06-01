---
key: INFRA-1508
status: filed
assignee: Doke
co_assignee: Steve Vives
reporter: Doke
created: 2026-06-01
filed: 2026-06-01
initiative: onprem-networking
parent_link: INFRA-472
labels: [design, dr, post-phase-1]
---

# Cross-cluster DR bootstrap design (SM source-of-truth chicken-and-egg)

## Context
On the 2026-05-29 networking/CySec call, Steve Vives flagged an unresolved DR weakness in the current SM-as-source-of-truth pattern [24:33]: *"that sucks because then you got like the chicken and the egg. That's the recovery from one end to the other — secrets manager, everything exists here, like how does that work?"*

The architecture: AWS Secrets Manager holds the canonical secrets (chosen for cloud↔on-prem lift-and-shift portability per [22:47]). Both EKS and on-prem clusters consume from SM via ExternalSecrets. If either side is the failover target during a DR scenario, the chicken-and-egg problem is: how does the recovering cluster bootstrap when it might depend on the cluster that's down?

This ticket scopes out a written design for the failover patterns. Forward-looking — defer execution to post-Phase-1.

## Scope

**In:**
- Enumerate the DR scenarios:
  1. AWS-region outage (cloud EKS unavailable) → on-prem absorbs workloads
  2. On-prem outage (cluster down) → cloud absorbs workloads
  3. AWS-account-wide outage (SM itself unreachable) → both sides degraded
- For each scenario, identify what bootstraps from what. Specifically:
  - Does the on-prem ExternalSecrets controller need anything that lives ONLY in the EKS cluster (e.g., a webhook, a CRD, a credential)?
  - Conversely, does any EKS workload depend on something only in on-prem (RW topology, Tim's pipeline state, etc.)?
- Identify the chicken-and-egg loops + propose breakers (e.g., cached creds with TTL, secondary KMS region, pre-staged bootstrap configs).
- Consider what changes if the etcd-at-rest research (separate ticket) lands a KMS-based pattern — does the KMS itself become a SPOF?
- Write up the failover runbook for each scenario.

**Out:**
- Actual implementation of failover automation (huge — separate phase).
- Disaster recovery testing (separate ticket once design is approved).
- Cross-region SM replication (probably out — SM is already global; verify).

## Definition of done
- [ ] Design doc `docs/designs/cross-cluster-dr-bootstrap.md` with 3 scenarios × bootstrap order × chicken-and-egg breaks
- [ ] Concrete list of "what would need to change" to enable each failover direction
- [ ] Estimated implementation roadmap (gross — week-level granularity)
- [ ] Steve Vives + Brendan + Duck reviewed

## Suggested approach
Start from the existing portability constraint (SM is the anchor). Walk through each scenario asking: at T-0 of failover, what does the receiving cluster need that it can't get? Then design the smallest pre-staging that breaks the loop.

For "AWS region outage" specifically — SM is technically multi-region by default for some operations (replication), but cross-region failover isn't free. Worth verifying with cloud team how the org's SM is configured.

## Constraints
- Pure design ticket. No code, no Terraform.
- **Post Phase 1** — don't start until INFRA-1494 ships (Phase 1 is the priority).
- Coordinate with cloud team for SM cross-region story.

## Links
- Parent initiative: [INFRA-472](https://usxpress.atlassian.net/browse/INFRA-472)
- 2026-05-29 call review: `wip/onprem-networking/networking-call-review-may29.md`
- Vives quote: see "Notable quotes" section of the review doc, [24:33]
- Related: "Research + recommend etcd encryption-at-rest pattern" (if KMS becomes the new SPOF, this design needs to account for it)

## Estimate
L — design + 3-person review. ~3 days focused, calendar 2 weeks including reviews. Defer to post-Phase-1.

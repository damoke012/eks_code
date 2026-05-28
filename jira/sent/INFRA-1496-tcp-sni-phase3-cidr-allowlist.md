---
key: INFRA-1496
status: filed
assignee: Doke
reporter: Doke
created: 2026-05-28
initiative: onprem-networking
labels: [onprem, networking, security, cilium, networkpolicy, phase3]
issuetype: Sub-task
parent: INFRA-1492
---

# Phase 3 — Source-CIDR allow-list via CiliumNetworkPolicy on gateway pods

## Context
TLS encrypts in transit but doesn't restrict reach. Lock the gateway DaemonSet pods to corp VPN CIDR(s) only, so unauthorized sources get a TCP reset before the TLS handshake.

Note: gateway uses hostPort + DaemonSet, so packets arrive on the worker's NIC. Cilium NetworkPolicy enforcement on hostPort traffic needs verification — if it doesn't filter, fallback is worker-level iptables (escalate to network team) or eventual BGP / MetalLB which routes through Cilium.

## Scope

**In:**
- `CiliumNetworkPolicy` in `istio-ingress` ns selecting gateway DaemonSet pods.
- Allow ingress from corp VPN CIDR(s) on TCP ports (80, 443, 4567, 5432 — match what's actually wired).
- Default deny on those ports from any other source.
- Verification probe from outside corp CIDR confirming reject.
- ConfigMap or annotation documenting the allowed CIDR list for future review.

**Out:**
- Per-namespace backend NetworkPolicies (Phase 4).
- L7 policy (TCP is opaque under passthrough).
- Worker-level iptables fallback unless Phase 3 enforcement test fails.

## Definition of done
- [ ] CiliumNetworkPolicy applied via Flux
- [ ] Verified positive: TCP connect from corp VPN succeeds (psql + curl)
- [ ] Verified negative: TCP connect from outside corp CIDR is rejected (use a Codespace or external test host)
- [ ] If enforcement fails on hostPort traffic, escalation note filed and worker-iptables fallback documented
- [ ] No RW degradation

## Suggested approach
1. **Confirm Cilium enforces on hostPort traffic** — check Cilium docs version we're running, and/or stage a tiny test policy on an unused port first.
2. **Identify corp VPN CIDR list** — coord with Steve / network team (likely already in some doc).
3. **Author CNP** with one rule per allowed CIDR + a default-deny pattern.
4. **Stage in audit/log mode first** if Cilium supports it; observe drops before enforcing.
5. **Cut over to enforce**; verify both positive and negative paths.

## Constraints
- Don't lock out legitimate users — start with a generous CIDR if you have ambiguity, then narrow.
- Cilium NP on hostPort may not work — design doc flags this risk. Have iptables/firewall fallback in mind.

## Links
- Parent: [TCP/SNI ingress umbrella]
- Design doc: [`docs/designs/tcp-sni-ingress-design.md#phase-3`](https://github.com/damoke012/eks_code/blob/main/docs/designs/tcp-sni-ingress-design.md)
- Cilium NP docs: https://docs.cilium.io/en/stable/network/kubernetes/policy/

## Estimate
S — single policy resource + verification. Could grow to M if Cilium-on-hostPort enforcement turns out not to work.

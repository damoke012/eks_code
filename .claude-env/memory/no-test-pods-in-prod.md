---
name: no-test-pods-in-prod
description: Never spin up ad-hoc test/debug pods in production clusters — use existing telemetry and running pods instead
metadata: 
  node_type: memory
  type: feedback
  originSessionId: e3125f37-c991-4364-adf2-b40770a2d61c
  modified: 2026-07-30T14:46:22.420Z
---

**Never create ad-hoc test pods in a production cluster.** No `kubectl run dnstest --rm`, no busybox/netshoot
throwaways, no `kubectl debug` on a prod workload — not even short-lived, not even with `--rm`.

Told to me directly 2026-07-30 during the prod DNS incident, after I suggested
`kubectl run dnstest --rm -i --image=busybox` on `usxpress-prod` to test resolution.

**Why:** it's unreviewed workload creation in prod. It pulls an unvetted external image, lands on a
Karpenter-managed node, gets an Istio sidecar and a workload identity, and is invisible to change control.
It also muddies incident telemetry with a pod nobody else knows about. In this case it was **pure waste** —
the CoreDNS logs had already shown `i/o timeout` to the corporate forwarders `10.10.90.10` / `10.10.92.10`
and named the failing zone. The test pod confirmed nothing that wasn't already established.

**How to apply — get the same evidence without creating anything:**
1. **Read the telemetry first.** CoreDNS/app logs, `kubectl get events`, Prometheus, AWS upgrade-readiness
   and VPC/endpoint status usually answer it outright.
2. **Exec into a pod that is already running** and already has the dependency — the app that is failing is
   the most faithful vantage point anyway.
3. Reproduce in **dev or QA**, which share the same corporate DNS forwarders and network paths.
4. Node-level checks via SSM Session Manager, not a pod.

If a prod-side probe is genuinely the only way, it is a change to be **proposed and confirmed first** — say
what image, what it does, how long it lives — never slipped into a list of diagnostic commands.

Related: [[eks-human-access-model]] (prod access is read-only `view` by design — creating pods is outside
that grant anyway), [[wsl-kubeconfig-churn]] (always confirm the context before acting).

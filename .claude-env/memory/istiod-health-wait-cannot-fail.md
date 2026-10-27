---
name: istiod-health-wait-cannot-fail
description: "iaac-talos deploy.ps1 waits up to 20 min for istiod and DISCARDS both error streams, so 'cannot reach the cluster' and 'zero ready replicas' are the same empty string. It hangs the full 1200s on op-qa and qa2 while istiod is healthy, then skips WITHOUT failing the deploy."
metadata:
  type: project
---

`deploy/deploy.ps1` lines ~264-282, post-apply:

```powershell
$istiodReady = bash -c "kubectl get deployment istiod -n istio-system \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null" 2>$null
if ($istiodReady -ge 1) { break }
```

**Both error streams are discarded.** A cluster the worker cannot reach and a Deployment with
zero ready replicas both yield the empty string, so the loop cannot tell them apart and waits
out all 1200 seconds either way.

**Measured 2026-10-26 on op-qa**: the loop sat at `Waiting for istiod... (600/1200)` while
`istiod` was `1/1 Running`, `0` restarts, **111 days old**, `Available: True`. Nothing had
rolled — the control planes were 112d and Ready.

✅ **It does NOT fail the deploy.** On timeout it prints *"istiod did not become ready in
time, skipping health check"* and continues, with no `exit 1`. So the cost is 20 wasted
minutes, not a failed deployment — and **qa2's 0.5.0 failure on 2026-09-17 was something
else**, not this.

**Why:** the comment above it says *"Flux needs 10-15 min to deploy: cert-manager → issuers →
istio-csr → istiod"*. The wait was written for a **fresh cluster bootstrap** where istiod does
not exist yet. On an existing cluster it should return on the first poll and does not.

⚠️ **It passes on development and hangs on op-qa and qa2.** Same release, same code, so the
difference is in how the Octopus worker reaches those clusters — unresolved, and the obvious
suspect is the kubeconfig the worker builds per environment.

**How to apply:** expect any `iaac-talos` deploy to op-qa or op-prod to sit 20 minutes at
`[HEALTH] Waiting for istiod` and then carry on. Do not read it as a symptom, and do not
cancel the deploy over it. The fix is to keep stderr and distinguish the two cases — see
[[transport-failure-not-a-verdict]] and [[a-guard-can-measure-the-wrong-thing]].

Related: [[octopus-green-but-no-apply]], [[adjacent-step-green-signals]].

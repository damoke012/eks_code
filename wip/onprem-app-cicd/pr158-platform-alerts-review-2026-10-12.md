# Review: iaac-talos-flux-platform#158 — INFRA-1693 alert fixes + Teams noise

Author ifagbemi-usxpress. Base **op-dev** (correct — not the bare `dev` trap). Head
`fix/infra-1693-teams-alert-format-op-dev` @ a931e9f5. +119/-7 across 4 files. 6 checks green.

**Verdict: APPROVED with 5 advisories, no blockers.** Net improvement: fixes three real rule
bugs and replaces an opt-out Teams receiver (33 alerts, including permanent false positives)
with opt-in routing.

**No Tim coordination needed.** Nothing is applied into the `risingwave` namespace — these are
PrometheusRules in `prometheus` that reference it.

## Cleared by independent verification

| Claim | Evidence |
|---|---|
| The new rule will actually load | Prometheus `ruleSelector` is `matchLabels: {release: prometheus-stack}`; `argocd-alerts.yaml` carries exactly that label, same as the working `risingwave-health` rule |
| `ArgoControllerDown` selector matches something | `argocd-application-controller` is a **StatefulSet**; `statefulset=~"argocd.*controller.*"` matches it |
| The suppressed alertnames are real, not typos | All five exist as rules: ClusterDNSUnreachable, KubeControllerManagerDown, KubeProxyDown, KubeSchedulerDown, TargetDown |
| `team="risingwave"` route is live | 4 alerts carry that label (29 carry `team: platform`, 177 carry none) |
| Route ordering suppresses before delivering | Child routes are first-match; the five `null` routes precede the `severity="critical"` route, so suppressed criticals stay suppressed |
| `argocd-alerts.yaml` is enumerated | `kustomization.yaml` adds it; that directory enumerates, so an unlisted file would be a silent no-op |

⚠️ **I got one wrong.** I first called `team="risingwave"` a dead route, having generalised
from the two alerts visible in the diff hunk to the whole rule set. Live, 4 alerts emit it.
One sample is not a population — the diff hunk is a sample.

## Advisories

1. **The `phase="Running"` join blinds both PodNotReady alerts to `Pending`.** The stated
   rationale is completed Jobs, but the RW pod regex is
   `risingwave-(meta|frontend|compute|compactor)-.*`, which never matched the `rw-bootstrap-*`
   Jobs anyway. What it does change: during today's upgrade dev's pods sat `phase=Pending,
   ready=false` for ~5 minutes on a 2.49 GB image pull. A pod stuck in Pending permanently —
   bad digest, unschedulable, no `pool=platform` node — is now unalertable. Suggest
   `phase!="Succeeded"`, or a separate Pending-too-long alert. Same gap in `ArgoPodNotReady`.
2. **`TargetDown` is suppressed, and every rule in this PR depends on kube-state-metrics.**
   If that stops being scraped, all six Argo alerts and both RW alerts go silent and the one
   signal that would say so is routed to null. Suggest keeping TargetDown for
   `job=~"kube-state-metrics|node-exporter"` or for the prometheus/kube-system namespaces.
3. **`ArgoContainerOOMKilled` will itself be noisy.**
   `kube_pod_container_status_last_terminated_reason` persists for the pod's lifetime, so with
   `for: 0m` it fires continuously once a container has ever been OOMKilled, until the pod is
   replaced. Pair it with a recency condition. (The pre-existing
   `RisingWaveContainerOOMKilled` has the same shape — not a regression, but worth fixing
   together.)
4. **`ArgoControllerDown` conflates two controllers.** `deployment=~"argocd.*controller.*"`
   also matches `argocd-applicationset-controller` (a Deployment), while the summary says the
   *application* controller is down and sync has stopped. Either split them or soften the text.
5. **`risingwave-console` is outside the RW pod regex while a container is crashlooping.**
   Measured 2026-10-12: prod's `risingwave-console` container has **restarts=532, lastReason
   Error**, and the pod reports `ready=true` — so neither the crashloop alert (console not in
   the regex) nor the not-ready alert (pod is ready) can see it. Dev's is restarts=2,
   lastReason Completed, so this is prod-specific. Out of scope for this PR; worth its own
   ticket, and it argues for adding console to the regex.

## Proven / tested and killed / not verified

**Proven:** the ruleSelector/label match, the controller kind and name, the existence of all
five suppressed alertnames, the live `team` label distribution, and prod's console restart
count.
**Tested and killed:** that `team="risingwave"` was a dead route.
**Not verified:** that the Alertmanager config actually reloads cleanly with the new routes
(the `inhibit_rules` block was only partly visible in the diff), and whether Teams delivery
works end to end after the change — Idris's own test plan covers both and they need the merge
first.

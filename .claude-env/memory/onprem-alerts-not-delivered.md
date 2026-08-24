---
name: onprem-alerts-not-delivered
description: "op-usxpress-dev has ~40 alert rules and 54 firing alerts with no Alertmanager (2026-08-21). The Flux rules were dead for FOUR reasons in series, all fixed on dev+QA 2026-08-24; prod pending. INFRA-1658/1659 open."
metadata: 
  node_type: memory
  type: project
  originSessionId: 40ffcbe4-704c-4f87-a520-f0a0a86445b7
  modified: 2026-08-24T17:20:00.000Z
---

**2026-08-21, op-usxpress-dev only.** Two independent gaps, both proven, found while
verifying the day's platform PRs:

1. **Nothing delivers alerts.** Prometheus CR `.spec.alerting` is `null`, zero
   alertmanager pods; `alertmanager.enabled: false` in the kube-prometheus-stack values in
   `infrastructure/prometheus/helmrelease.yaml` on branch `op-dev`. **54 alerts firing**,
   oldest `ClusterDNSUnreachable` since 2026-06-24. Visible only in the Prometheus UI.
2. **The Flux rules cannot fire.** `gotk_reconcile_condition` → 0 series, `flux-system` →
   0 scrape targets. No ServiceMonitor or PodMonitor for it on `op-dev`. All four Flux
   rules from INFRA-1503 are permanently inactive — they did not fire on the two
   Kustomizations that were `Ready=False` for 2d18h, and never could.
   ⚠️ **Corrected 2026-08-24: that was the first of FOUR defects in series.** Fixing each
   one revealed the next; every intermediate state looked fixed. (a) nothing scraped
   `flux-system` — PodMonitor, PRs #114–#116; (b) `gotk_reconcile_condition` **does not
   exist** in this Flux version, so the PodMonitor gave 4 healthy targets and still 0
   series — replaced by kube-state-metrics CustomResourceState emitting
   `gotk_resource_info`, #117–#119; (c) `ready="False"` misses **cycling** failures — a
   health check that times out alternates `False`/`Unknown` every scrape (measured: True 0,
   False 59, Unknown 61 over 60m at 30s = exactly 120 = one object flapping), so
   `wiz-sensor` fired because it is *stalled* while `risingwave` sat `pending` for over an
   hour — `ready!="True"`, #120; (d) **`ready` and `revision` are inside the alert's own
   identity** — Prometheus keys an alert instance on the output label set, so the widened
   matcher still produced two alternating instances and `activeAt` still reset — fixed with
   `max by (customresource_kind, exported_namespace, name)`, #121 dev / #122 QA.
   A fifth defect surfaced in (d): every summary said `{{ $labels.namespace }}`, which is
   **kube-state-metrics' own namespace** (`prometheus`), not the Flux object's
   (`exported_namespace: flux-system`) — the page would have fired correctly and named the
   wrong namespace. `for: 10m` verified correctly sized: a `dependsOn` cascade peaks at 27
   Kustomizations not-Ready and decays to 4 within 3 minutes; exactly 2 survive a full
   window.

**The rule set is good** (~40 rules, correctly labelled `release: prometheus-stack`).
Authoring was never the problem; ingestion and delivery are.

`KubePersistentVolumeFillingUp` fired on `risingwave-2` at **2026-08-18T22:08:52**, 76
seconds after the pod began crashing, naming the pod and the cause. It was rediscovered by
hand on 2026-08-21.

**Why:** a PrometheusRule whose expression selects a metric that is never ingested is
valid, healthy, `inactive` and dead — see [[adjacent-step-green-signals]]. And
`alertmanager.enabled: false` is one values line that removes an entire capability with
nothing downstream complaining.

**How to apply:** `bash scripts/check-alert-delivery.sh --context <ctx>` answers all three
questions (sink exists / each rule's metric exists / what has been firing over a week) —
⚠️ its metric extractor is still wrong for `on(...)`, `ignoring(...)`, `group_left(...)`
and inverts `absent()`, so its "cannot fire" list contains false positives (~81 on dev).
**Reaching `firing` once is not a pass** — three of the four INFRA-1657 fixes produced a
`pending` or a brief `firing`. Only holding across several flips distinguishes a working
rule from a resetting one.
Run it per cluster — **QA and prod are NOT measured**, and QA has an extra
`prometheus-rules` Kustomization dev lacks, so its result cannot be assumed.
Tickets, in dependency order: **INFRA-1657** *make the Flux rules actually fire* (re-scoped
2026-08-24 from "scrape flux-system"; dev shipped + verified, QA merged, **prod pending**),
**INFRA-1658** triage the 54 before delivery, **INFRA-1659** deliver (a design decision, not
a values change) — all under epic INFRA-1632. INFRA-1642 keeps only the Flux-token-at-source half.
Full record: `wip/observability/FINDINGS-2026-08-21-alerts-reach-nobody.md`.

⚠️ **Triage the 54 before enabling delivery.** `KubeControllerManagerDown` has fired since
2026-06-24 and is very likely a Talos false positive (control-plane components are static
pods the default scrape config misses). Delivering two months of unreviewed backlog on day
one trains everyone to ignore the channel. Related: [[onprem-app-cicd]],
[[prod-incident-instrument-check]].

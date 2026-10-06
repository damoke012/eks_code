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

---

## ✅ 2026-09-18 — QA measured for the first time. The claim holds; the numbers differ.

Everything above was **op-usxpress-dev only**, and this note said so. It was nonetheless
quoted as a fleet fact more than once. Now measured on **op-usxpress-qa** (10.10.82.51):

```
FAIL  Prometheus CR has NO .spec.alerting — firing alerts go nowhere
FAIL  no alertmanager pod in prometheus
22 firing, 8 of them for over a week
116 rules have live metrics, 81 flagged unable to fire
```

So the delivery gap is confirmed on two of three clusters. **Prod is still not measured.**

**Read the ages before believing them:**
- The seven oldest all start at `2026-07-14T17:57`, **including `Watchdog`** — which fires
  the moment Prometheus starts. That timestamp is Prometheus's own boot, not an incident.
  `KubeProxyDown` / `KubeControllerManagerDown` / `KubeSchedulerDown` are the Talos
  static-pod false positives, same as dev.
- Ten of the 22 carry `pod=prometheus-stack-kube-state-metrics-…` inside their label set, so
  the KSM restart on 2026-09-14 reset their `activeAt`. **Their true ages are unknown, not
  recent.** Same defect as INFRA-1657, still present in the shipped rules.

**🔴 The one that matters:** `EtcdSnapshotJobFailing` ×5 and `KubeJobFailed` ×5 in
`etcd-backup`. **QA's etcd backups are failing**, age unknown per the point above. A live
data-loss exposure on the cluster running RisingWave, undetected purely because nothing
delivers. File it ahead of the delivery work, not inside it.

**`ClusterDNSUnreachable` (critical, ours) is a false positive**: `probe_success` has no
series because there is no blackbox exporter. It is an `absent()` rule reporting a missing
probe. Do not read it as a DNS outage.

**On the 81 "cannot fire":** treat as an upper bound, per the extractor caveat above.
Entries naming a real metric are credible — and
`certmanager_certificate_expiration_timestamp_seconds` is among them, so **certificate-expiry
alerting does not work on QA**. Entries whose "no series" list is bare label names
(`cluster namespace owner_kind pod`) are the bug.

Grafana was *not* the blocker it appeared to be — see
[[helmrelease-ready-hides-failed-history]]. It has been running for 72 days; what was broken
was Flux's ability to deliver changes to it.

## 2026-10-05 — the "On-Prem Platform" Teams channel is NOT fed by the on-prem clusters

Steve Duck reported the channel is noisy and asked for Idris's PR to be reviewed to quieten
it. Measured before reviewing anything, across all three clusters:

```
kubectl --kubeconfig=<each> get providers.notification.toolkit.fluxcd.io,alerts.notification.toolkit.fluxcd.io -A
op-usxpress-qa    No resources found   (notification-controller 1/1, 90d)
op-usxpress-dev   No resources found
op-usxpress-prod  No resources found
```

Zero Flux notification Providers and zero Alerts on **all three**, and no Alertmanager on any
of them. So the channel's traffic originates **outside the on-prem clusters** — Octopus,
GitHub Actions, Azure Monitor, Grafana or a cloud EKS cluster. Unidentified as of today; the
cheapest answer is whoever configured the Teams connector, not more cluster searching.

**Two true things at once, and they are easy to conflate:** the channel is noisy, AND on-prem
alerting does not exist. Quietening the channel does not advance INFRA-1698, and a PR aimed
at the alert rules would merge green and change nothing in that channel.

⚠️ **`~/.kube/op-usxpress-dev.yaml` on Doke's WSL points at CLOUD EKS `qa-one`**
(`D0E66CB97...gr7.us-east-2.eks.amazonaws.com`), not 10.10.82.50. The real on-prem dev config
is `op-usxpress-dev-fresh.yaml`. An expired token is the only reason the first dev query did
not return a confident "No resources found" **from the wrong cluster**. Verify the server
address before trusting a kubeconfig's filename:

```bash
for f in "$HOME"/.kube/*.yaml; do echo "== $f"; kubectl --kubeconfig="$f" config view \
  -o jsonpath='{range .clusters[*]}{.name}  {.cluster.server}{"\n"}{end}'; done
```

On-prem is `10.10.82.50/.51/.52`. Anything `eks.amazonaws.com` is cloud. `dare-cluster` (.20)
and `dpl2-cluster` (.30) are the decommissioned clusters (INFRA-1686) and should not be in
that directory at all. See [[proxy-is-not-the-property]], [[wsl-kubeconfig-churn]].

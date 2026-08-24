# op-usxpress-dev has ~40 alert rules, 54 firing alerts, and no way to tell anyone

**2026-08-21.** Found while verifying today's nine platform PRs with
`scripts/check-onprem-platform-state.sh`, which reported two Kustomizations
`Ready=False`. Chasing why nobody knew turned up something larger than the
Kustomizations.

Scope: **op-usxpress-dev** (10.10.82.50), measured 2026-08-21 ~16:40 UTC. QA and prod
are **not** measured — see *Not checked* below. Numbers carry that scope.

---

## What is proven

**1. Nothing delivers alerts. There is no Alertmanager.**

```
$ kubectl -n prometheus get prometheus -o json | jq '.items[].spec.alerting'
null

$ kubectl -n prometheus get pods | grep -c alertmanager
0
```

`infrastructure/prometheus/helmrelease.yaml` on branch `op-dev` sets
`alertmanager.enabled: false` in the kube-prometheus-stack values. Prometheus evaluates
every rule correctly and has nowhere to send the result. A firing alert is visible only
to someone who opens the Prometheus UI and clicks *Alerts*.

**54 alerts were firing at the time of measurement.** Among them, with their `activeAt`:

| Alert | Firing since | Age at discovery |
|---|---|---|
| `ClusterDNSUnreachable` | 2026-06-24 | 2 months |
| `KubeControllerManagerDown` | 2026-06-24 | 2 months |
| `KubePodNotReady attrition/attrition-api-*` | 2026-06-24 | 2 months |
| `KubePodNotReady io-curt/io-notifications-handler-*` | 2026-07-28 | 3 weeks |
| `KubePodNotReady wiz/wiz-sensor-*` | 2026-07-21 | 1 month |
| `CephClusterHealthWarn` | 2026-08-17 | 4 days |
| `KubePodCrashLooping risingwave-2/prometheus-server-*` | 2026-08-18T22:07:42 | 2d18h |
| `KubePersistentVolumeFillingUp risingwave-2` | 2026-08-18T22:08:52 | 2d18h |

That last pair is the sharpest fact in this note. **The cluster diagnosed the RisingWave
Prometheus outage 76 seconds after it began**, named the pod and named the cause, and then
held that answer silently for two and a half days while we rediscovered it by hand.

**2. The Flux alerts cannot fire, because the metric is never ingested.**

> ⚠️ **Corrected 2026-08-24.** True, but this was the *first of four* independent
> reasons, not the reason. Fixing it revealed the second, which hid the third,
> which hid the fourth. See *INFRA-1657 needed four PRs* below.

```
gotk_reconcile_condition series:  0
flux targets scraped:             0
Flux alerts in any state:         (none)
```

`platform-alerts.yaml` (INFRA-1503) ships four Flux rules —
`FluxKustomizationFailed`, `FluxHelmReleaseFailed`, `FluxGitRepositoryFailed` and their
group — all keyed on `gotk_reconcile_condition`. Nothing scrapes `flux-system`: there is
no ServiceMonitor or PodMonitor for it anywhere on branch `op-dev`
(`git ls-tree -r --name-only origin/op-dev | grep -i "servicemonitor\|podmonitor"` → empty).

A PrometheusRule whose expression selects a metric that is never ingested is **permanently
inactive**. It is not an error. `kubectl get prometheusrule` shows it present. The
Kustomization that ships it is `Ready=True`. Prometheus's own rule evaluation reports no
failure — an expression matching zero series is a valid expression returning nothing.
There is no signal anywhere in the stack that a rule is dead.

So the two Kustomizations that were `Ready=False` for 2d18h never fired the rule written
for exactly that case. This is not the Alertmanager gap; it is separate and upstream of it.
Fixing delivery alone would still leave every Flux rule dead.

**3. The rule set itself is good.** ~40 rules across `platform-alerts.yaml`,
`rook-ceph-health.yaml`, `etcd-cluster-health.yaml`, `etcd-snapshot-age.yaml`,
`dns-health.yaml`, `irsa-health.yaml`, `istio-cert-chain.yaml`,
`cilium-node-divergence.yaml`, `control-plane-memory.yaml`, plus kube-prometheus-stack's
defaults. They are well written, labelled `team: platform` / `track: storage`, and
correctly selected by `release: prometheus-stack`. **The authoring was never the problem.**

---

## What we believed that was wrong

Three corrections, in the order they were made today, because the sequence is the lesson:

1. *"Nothing was watching the Flux Kustomizations."* — **Wrong.** `FluxKustomizationFailed`
   has existed since INFRA-1503.
2. *"The rule exists, so it fired and reached nobody."* — **Wrong.** It never fired; the
   metric does not exist. Corrected by noticing `Flux*` was absent from a list sorted
   alphabetically where `F` would have preceded the visible `K` entries.
3. *"Dev's platform Prometheus volume is at 95% and one restart from death."* — **Wrong.**
   `rbd du` reports **allocated** RBD blocks, not filesystem usage. `df -h /prometheus`
   says 11.5G of 19.9G, **58%**. The ~8 GiB gap is blocks TSDB freed at the filesystem
   layer that were never released to RBD (no discard/fstrim). `rbd du` is not a
   disk-usage instrument for a filesystem-backed volume.

Correction 3 is the [[prod-incident-instrument-check]] lesson, made within an hour of
citing it. `risingwave-2`'s volume was genuinely full — but that is proven by the
application's own `no space left on device`, not by `rbd du`.

---

## 2026-08-24 — INFRA-1657 needed four PRs, not one

Scope: **op-usxpress-dev**, verified live; **op-usxpress-qa** merged and not yet observed;
**op-prod** not yet shipped.

The 2026-08-21 note treated "nothing scrapes `flux-system`" as the defect. It was one layer
of four. **Each layer was completely invisible until the one above it was fixed**, and at
every layer the obvious check reported success.

| # | Defect | What it looked like once fixed | PRs |
|---|---|---|---|
| 1 | Nothing scraped `flux-system` | 4 targets, all `up`, no errors — and still **0 series** | #114 #115 #116 |
| 2 | `gotk_reconcile_condition` **does not exist** in this Flux version | replaced by KSM CustomResourceState `gotk_resource_info`; 77 series appeared | #117 #118 #119 |
| 3 | `ready="False"` misses **cycling** failures | `wiz-sensor` fired, `risingwave` sat `pending` >1h | #120 |
| 4 | `ready` and `revision` are **in the alert's own label set** | matcher widened, series still discontinuous, window still never completed | #121 #122 |

**Layer 2.** The controllers expose only `gotk_reconcile_duration_seconds`. A working
scrape of a metric that is never emitted is indistinguishable from no scrape at all — four
healthy targets and zero series for the thing the rules need.

**Layer 3.** `flux-system/risingwave`'s health check times out at 5m and re-runs. Ready goes
`Unknown` while it runs and back to `False` on timeout. Measured over 60 minutes at a 30s
scrape — 120 samples for one series:

```
ready="True"      0 samples
ready="False"    59 samples
ready="Unknown"  61 samples      59 + 61 = 120 exactly: one object, alternating, never True
```

`wiz-sensor` fired correctly throughout, because it is **stalled** and its condition sits
still. So the rule worked for stalled failures and silently failed for cycling ones — and
one of the two firing is exactly what would have let us call the ticket finished.

**Layer 4, the subtle one.** Prometheus identifies an alert instance by **the label set of
the expression's output**. `ready` was in that set. So `ready!="True"` widened the match but
a flapping object *still* produced two alternating instances — `False` and `Unknown` — each
vanishing as the other appeared, each resetting `activeAt`. The 10-minute `for:` window
still never completed. `revision` churns identically, changing on every successful apply.

The measurement that exposed it, and the one that hid it:

```
count(count_over_time(gotk_resource_info{...ready!="True"}[10m]) >= 20)          = 1
same, with max by (exported_namespace, name) applied first                       = 2
```

Two Kustomizations had been not-Ready for days. The unaggregated count sees only
`wiz-sensor`. **My own verification query counted per-series exactly the way the broken
alert did, returned `1`, and I read it as a result rather than as the bug reporting
itself.** Fixed with `max by (customresource_kind, exported_namespace, name)`.

**A fifth defect, found while fixing the fourth.** Every Flux summary said
`{{ $labels.namespace }}`. That is kube-state-metrics' *own* namespace — its ServiceMonitor
stamps `namespace="prometheus"` onto every series it emits, which is precisely why the CRS
config had to name the real one `exported_namespace`:

```
exported_namespace=flux-system     <- the Kustomization
namespace=prometheus               <- kube-state-metrics' pod
```

The page would have fired correctly and named the wrong namespace. After `max by()` drops
`namespace`, it would have rendered empty instead. Repointed to `exported_namespace` in the
same PR. Other rules in the file keep `$labels.namespace`, correctly — `kube_pod_*` carries
a real one.

**`for: 10m` is confirmed correctly sized.** A mass reconcile fans out through `dependsOn`
and puts many Kustomizations `Ready=False` at once: peak breadth **27**, decaying to 4
within three minutes. Exactly **2** objects survive a full 10-minute window, which is the
two genuinely broken ones. The widened matcher does not storm.

### Two guard bugs, same shape

Both scripts written to make these changes safely refused a branch that was already correct:

- `pr-flux-alert-ready-not-true.sh` searched the whole file for `gotk_reconcile_condition`
  and matched **the comment block explaining that it is no longer used** — reading its own
  documentation as evidence of the defect that documentation says was fixed.
- `pr-flux-alert-aggregate.sh` asked "is this note already present?" by comparing the note
  to itself **byte-for-byte**; the existing one carried a `⚠️` and a longer closing
  sentence, so it appended a near-duplicate paragraph.

Both fixed by keying on a stable distinguishing feature — expressions with comments
stripped, and the phrase `"second correction"` — rather than on full text. Both
fixture-tested against every branch state before shipping.


---

## Traps

- **A rule referencing an unscraped metric is silently inert.** Every status field in the
  chain is green: rule present, Kustomization Ready, Prometheus healthy, expression valid.
  The only way to know is to query the metric.
- **`alertmanager.enabled: false` is a one-line values setting that disables an entire
  operational capability**, and nothing downstream complains. The rules keep being written,
  reviewed and merged.
- **`rbd du` ≠ `df`.** Allocated blocks, not used bytes, and the difference on a
  TSDB volume is large.
- **A fixed layer reveals the next one, and each looks like the last.** Four times on this
  ticket the fix was verified by a check that shared the defect it was checking for: a
  healthy scrape of a non-existent metric, a firing `wiz-sensor` masking a broken
  `risingwave`, a per-series count that split exactly the way the alert did.
- **The alert's identity is its output label set.** Any label that churns — `ready`,
  `revision`, anything derived from status — resets `activeAt` on every change and prevents
  a `for:` window from ever completing. Aggregate the volatile labels away.
- **`$labels.namespace` on a kube-state-metrics CRS series is KSM's namespace, not the
  object's.** The real one is `exported_namespace`. The alert is right and the text is wrong,
  which is worse than an obviously broken alert.
- **Reaching `firing` once is not the test.** Three of the four fixes produced a `pending`
  or a brief `firing`. Only holding across several flips distinguishes a working rule.
- **Noise and silence are indistinguishable to the recipient.** `KubeControllerManagerDown`
  has been firing for two months and is very likely a Talos false positive (the
  control-plane components are static pods that the stack's default scrape config does not
  reach). Turning delivery on without triaging the existing 54 would deliver two months of
  accumulated noise on day one and train everyone to ignore it.

---

## Not checked

**op-usxpress-qa and op-usxpress-prod were not measured.** QA has an extra
`prometheus-rules` Kustomization that dev does not, so its rule set is not identical and
its result cannot be assumed from dev's. Prod was not reachable at all today. Per
CLAUDE.md rule 5, no claim here extends beyond dev until each is run.

The same three commands answer it per cluster — they are in *Reproduce* below.

---

## Reproduce

```bash
kubectl --context <ctx> -n prometheus get prometheus -o json \
  | jq '.items[] | {alerting: .spec.alerting}'
kubectl --context <ctx> -n prometheus get pods | grep -c alertmanager

kubectl --context <ctx> -n prometheus port-forward \
  svc/prometheus-stack-kube-prom-prometheus 9090:9090 >/tmp/pf.log 2>&1 &
sleep 3
curl -s 'localhost:9090/api/v1/query?query=gotk_reconcile_condition' | jq '.data.result | length'
curl -s 'localhost:9090/api/v1/targets?state=active' \
  | jq '[.data.activeTargets[] | select(.labels.namespace=="flux-system")] | length'
curl -s localhost:9090/api/v1/alerts | jq '[.data.alerts[] | select(.state=="firing")] | length'
kill %1
```

`<ctx>` is deliberate here — this block is documentation of a procedure, not a runnable
handover. The runnable form is `scripts/check-alert-delivery.sh`, which takes `--context`.

---

## The work this implies

Three separate pieces, in dependency order, filed 2026-08-21 under epic INFRA-1632.
None is a one-liner and none should be folded into another:

1. ~~**INFRA-1657 — scrape `flux-system`.** A PodMonitor for the Flux controllers on all three branches.
   Without it every Flux rule stays dead, delivered or not. Smallest of the three.~~
   **Re-scoped 2026-08-24: "make the Flux rules actually fire."** It was not the smallest of
   the three and it was not a PodMonitor. Four defects in series, five counting the
   annotation — see the section above. Dev shipped and verified; QA merged; prod pending.
2. **INFRA-1658 — triage the 54.** Before delivery is switched on. Decide per alert: real and to be
   fixed, real and to be silenced with a reason, or a false positive whose rule needs
   correcting (`KubeControllerManagerDown` on Talos is the archetype). Delivering an
   unreviewed backlog is how an alerting channel dies in its first week.
3. **INFRA-1659 — deliver.** Alertmanager, or a routing integration, on all three clusters, to a
   destination someone watches. This is a design decision — Teams vs PagerDuty vs email,
   who is on the other end, what severity routes where — not a config change.

**Proven:** dev has no Alertmanager; 54 alerts firing, oldest 2026-06-24; the RisingWave
outage was correctly detected at 2026-08-18T22:08:52. The Flux rules were dead for four
independent reasons in series (2026-08-24), all four now fixed on dev and QA; `for: 10m` is
correctly sized against a peak `dependsOn` cascade of 27.
**Tested and killed:** "the Flux rule fired and went nowhere" (it never fired); "the
platform Prometheus volume is at 95%" (58%, `rbd du` was the wrong instrument); "the missing
`flux-system` scrape was the cause" (first of four); "`ready!=\"True\"` fixes the flapping
case" (it does not — the label is in the alert's own identity); "1 object would page" (the
counting query had the same per-series defect as the alert).
**Traps:** an unscraped rule is silently inert; a scraped-but-never-emitted metric looks
identical to it; a churning label in the output resets `activeAt` forever; `$labels.namespace`
on a CRS series is KSM's namespace; `rbd du` is not `df`; reaching `firing` once proves
nothing; turning on delivery before triage delivers two months of noise.

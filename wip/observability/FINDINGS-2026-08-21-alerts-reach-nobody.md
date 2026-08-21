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

## Traps

- **A rule referencing an unscraped metric is silently inert.** Every status field in the
  chain is green: rule present, Kustomization Ready, Prometheus healthy, expression valid.
  The only way to know is to query the metric.
- **`alertmanager.enabled: false` is a one-line values setting that disables an entire
  operational capability**, and nothing downstream complains. The rules keep being written,
  reviewed and merged.
- **`rbd du` ≠ `df`.** Allocated blocks, not used bytes, and the difference on a
  TSDB volume is large.
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

Three separate pieces, in dependency order. None is a one-liner and none should be folded
into another:

1. **Scrape `flux-system`.** A PodMonitor for the Flux controllers on all three branches.
   Without it every Flux rule stays dead, delivered or not. Smallest of the three.
2. **Triage the 54.** Before delivery is switched on. Decide per alert: real and to be
   fixed, real and to be silenced with a reason, or a false positive whose rule needs
   correcting (`KubeControllerManagerDown` on Talos is the archetype). Delivering an
   unreviewed backlog is how an alerting channel dies in its first week.
3. **Deliver.** Alertmanager, or a routing integration, on all three clusters, to a
   destination someone watches. This is a design decision — Teams vs PagerDuty vs email,
   who is on the other end, what severity routes where — not a config change.

**Proven:** dev has no Alertmanager and no Flux scrape; 54 alerts firing, oldest
2026-06-24; the RisingWave outage was correctly detected at 2026-08-18T22:08:52.
**Tested and killed:** "the Flux rule fired and went nowhere" (it never fired); "the
platform Prometheus volume is at 95%" (58%, `rbd du` was the wrong instrument).
**Traps:** an unscraped rule is silently inert; `rbd du` is not `df`; turning on delivery
before triage delivers two months of noise.

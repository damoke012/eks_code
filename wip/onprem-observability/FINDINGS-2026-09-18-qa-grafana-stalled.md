# QA's Grafana has been unmanageable since 14 July, and it is running fine

**2026-09-18.** Found while confirming an epic ("Risingwave Alert") that assumed alerts
could be routed through Grafana. A devops agent had reported the HelmRelease as a HIGH
finding; confirming it turned up something different from what the agent concluded.

Scope: **op-usxpress-qa** (10.10.82.51), measured 2026-09-18 via the break-glass
kubeconfig. Dev and prod are **not** measured here. Numbers carry that scope.

---

## What is proven

### 1. The release is dead. The workload is not.

```
$ kubectl get helmrelease grafana -n grafana -o jsonpath='{.status.history[0].status}'
failed

Stalled: True   Reason: RetriesExceeded
Last Handled Reconcile At:               2026-07-14T15:43:35-04:00
Last Attempted Release Action:           install
Last Attempted Release Action Duration:  5m0.528513048s
Install Failures:                        4
Observed Generation:                     1      (first deployed 2026-07-07T23:52:50Z)
```

```
$ kubectl get pods,pvc -n grafana
pod/grafana-7996f6d86f-dpchf   3/3   Running   0 restarts   72d
pvc/grafana                    Bound  10Gi  RWO  ceph-block  72d
```

**Grafana has served for 72 days while Flux believed its install failed.** Flux has not
attempted an install since **14 July** — 66 days. Anything committed under
`infrastructure/grafana/` in that window reached nothing, and no status field says so.

This is the dangerous shape: *release broken, workload up*. Nobody investigates, because
the thing looks fine.

### 2. Two spec defaults produced it, in series

**`5m0.528513048s` is not an error, it is a deadline.** The HelmRelease sets no
`.spec.timeout`, so Helm allowed readiness the default five minutes. A first install that
had to provision a ceph-block PVC and pull images took longer. Helm recorded `failed`; the
pod became ready shortly after.

Then the recovery could not work:

```yaml
install:
  remediation:
    retries: 3          # and nothing else
```

`remediateLastFailure` **defaults to `false` for `install` and `true` for `upgrade`.** With
it false, each retry attempted an *upgrade* of a release whose only version was a failed
install — which Helm refuses. Four attempts against an error they could never clear, then
`RetriesExceeded`.

The asymmetry in those two defaults is the whole bug. Nothing in the object mentions it.

### 3. Alert delivery on QA — measured for the first time

Previously recorded as a dev-only finding. Now measured on QA:

```
FAIL  Prometheus CR has NO .spec.alerting — firing alerts go nowhere
FAIL  no alertmanager pod in prometheus
22 firing, 8 of them for over a week
116 rules have live metrics, 81 flagged as unable to fire
```

The seven oldest all begin at `2026-07-14T17:57`, **including `Watchdog`**. Watchdog fires
the moment Prometheus starts, so that timestamp is Prometheus's own boot — those seven have
been firing since the day it came up, not since an incident.

`ClusterDNSUnreachable` (critical, ours) is firing because `probe_success` has **no series**
— there is no blackbox exporter. It is an `absent()` rule reporting a missing probe, not a
DNS outage.

### 4. QA's etcd backups are failing, and nobody was told

```
EtcdSnapshotJobFailing  x5   ns=etcd-backup
KubeJobFailed           x5   ns=etcd-backup
```

⚠️ Their `activeAt` of 2026-09-14T16:40 is a **floor, not a fact**: all ten carry
`pod=prometheus-stack-kube-state-metrics-...` inside their label set, so the KSM restart on
14 September reset every one of their clocks. True ages are unknown.

This is a live data-loss exposure on the cluster running RisingWave, undetected only because
nothing delivers alerts. It is the epic's own argument, made for it.

---

## What we believed that was wrong

- **"Grafana on QA is broken / observability has no UI."** Wrong. Grafana is up and has been
  for 72 days. What is broken is Flux's ability to deliver *changes* to it. The remediation
  that follows from each belief is different, and the first one aims at a deployment that is
  not failing.
- **"The PVC never bound."** My hypothesis from the exact-5-minute timeout, stated before
  looking. It is `Bound`, on `ceph-block`. A 5-minute timeout means *waiting*, and waiting
  has more causes than storage.
- **"No sink anywhere on-prem" quoted from dev numbers.** The claim was right for QA too, but
  it was an inference until today. `wip/observability/FINDINGS-2026-08-21-alerts-reach-nobody.md`
  says plainly that QA and prod are not measured; quoting its numbers as fleet-wide ignored
  its own scope line.
- **The devops agent's read.** Its observation was correct and its inference was not: it
  ranked the HelmRelease HIGH as "critical path for observability" and proposed investigating
  a failed install. It never checked whether Grafana was running. The report also never asks
  whether any alert reaches a human — it measured the cluster, not the thing the epic is about.

---

## Did a procedure change

Yes, two.

**Verify a HelmRelease on its history, not its Ready condition.**

```
kubectl get helmrelease <name> -n <ns> -o jsonpath='{.status.history[0].status}{"\n"}'
```

Want `deployed`. `Ready` and the Helm history disagree in both directions, and the
disagreement is the finding.

**Before assigning severity to a failed release, count its pods.** *Release broken + workload
down* is an outage. *Release broken + workload up* is silent GitOps paralysis — lower urgency,
far longer half-life, and the one that will not be found by anyone watching dashboards.

---

## Could a check have caught it

Yes, and it now exists: **`scripts/check-helmrelease-truth.sh`**.

For every HelmRelease it compares `Ready`, `Stalled`, `history[0].status` and the running pod
count, and refuses to collapse the last two into one verdict. It also flags the two silent
defaults — a missing `.spec.timeout`, and `install.remediation` without
`remediateLastFailure` — plus a floating chart version, whatever the verdict.

The jq extraction was exercised against a fixture carrying QA's exact status shape before the
script was pointed at a cluster.

`scripts/check-onprem-platform-state.sh` checks Kustomizations and never looked at
HelmReleases. A Kustomization can be `Ready=True` while every HelmRelease it ships is failed —
which is exactly what QA reported: **43/43 Kustomizations True, 18/19 HelmReleases succeeded.**

---

## The fix

PR **variant-inc/iaac-talos-flux-platform#151**, branch `op-qa`:

| Change | Why |
|---|---|
| `spec.timeout: 15m` | a first install on this storage class needs more than five minutes |
| `install.remediation.remediateLastFailure: true` | clears the failed release so the retry is an install, not a doomed upgrade |
| `version: "8.15.0"` (was `"8.x"`) | the repair triggers a fresh chart resolve; pin to what is running so it is a like-for-like restore |

The commit bumps `metadata.generation`, which is what clears `Stalled` — Flux gives up per
generation, so a spec change is what restarts it. No manual `flux` command.

`pvc/grafana` was annotated `helm.sh/resource-policy=keep` so the uninstall does not take the
volume (`ceph-block` reclaims `Delete`). ⚠️ That annotation is a live edit and is **not in
Git**; the durable form is `persistence.existingClaim: grafana` in the `grafana-values`
ConfigMap, as a follow-up.

---

## Proven

- `grafana/grafana` on op-usxpress-qa: `Stalled=True/RetriesExceeded`, `history[0].status=failed`,
  no reconcile attempt since 2026-07-14, generation 1 since 2026-07-07 — while the pod ran
  3/3 with 0 restarts for 72 days.
- The cause is two Flux defaults in series: a 5-minute readiness timeout, then
  `install.remediation.remediateLastFailure` defaulting false where upgrade defaults true.
- op-usxpress-qa has **no Alertmanager and no `.spec.alerting`**; 22 alerts firing, 8 over a week.
- QA's etcd snapshot jobs are failing; their true age is unknown because the exporter is inside
  the alert's label set.

## Tested and killed

- **"The PVC never bound."** It is Bound on `ceph-block`.
- **"Grafana is down."** 3/3 Running, 72 days, 0 restarts.
- **"`ClusterDNSUnreachable` means DNS is broken."** `probe_success` has no series; there is no
  blackbox exporter. The rule reports a missing probe.
- **"The 81 unable-to-fire rules are 81 real gaps."** Entries whose "no series" list is bare
  label names (`cluster namespace owner_kind pod`) are the extractor's known bug. Entries naming
  a real metric (`etcd_*`, `certmanager_*`, `external_secrets_*`, `pilot_xds`, `ceph_*`) are
  credible — and `certmanager_certificate_expiration_timestamp_seconds` being absent means
  **certificate-expiry alerting does not work on QA**.

## Traps

- **A `Ready` HelmRelease can hold a `failed` history entry, and the reverse.** Read the history.
- **`Stalled=True` is terminal per generation.** Reconciling, waiting or suspending/resuming
  changes nothing; only a spec change restarts it.
- **`remediateLastFailure` defaults differently for install and upgrade.** Copying an
  `install.remediation` block that "works elsewhere" reproduces this exactly.
- **An alert's age is a floor, not a fact, when the exporter appears in its label set.** Ten of
  QA's 22 reset on a kube-state-metrics restart. Same defect as INFRA-1657.
- **`Watchdog`'s `activeAt` is Prometheus's boot time.** Any alert sharing that timestamp has
  been firing since start-up, not since an event.
- **A Kustomization being `Ready=True` says nothing about the HelmReleases it ships.**
- **`helm uninstall` takes the PVC** when the chart owns it and the storage class reclaims
  `Delete`. Annotate or move to `existingClaim` first.

---

## Outcome, same day

**#151** (grafana alone) merged 14:02, `history[0].status` `failed` → **`deployed`** at 14:08.
Proved the pattern before it was widened.

**#152** (the other 18 files) merged after it. Post-reconcile:
`FAILED: 0. UNKNOWN: 0. ADVISORY: 2` — from 35.

⚠️ **The first post-merge run read `ADVISORY: 32` and `FAILED: 0`, which looks like success.**
It was not: the advisories still described the *old* spec, because Flux had not reconciled yet.
The arithmetic gave it away — 35 → 32, and the three that cleared were grafana's, from #151.
A check that reads live objects is a statement about *this moment*, and the moment right after
a merge is the wrong one. `flux reconcile source git flux-system` then re-read.

**What remains is `risingwave/risingwave-operator`**, and it is out of the platform repo's
reach:

```
flux-system   infra                   op-qa@sha1:5d3c43c5        <- what #152 changed
flux-system   iaac-risingwave-onprem  v0.5.6@sha1:62e56b3d       <- where the operator lives
```

Fixing it means a change in `iaac-risingwave-onprem`, a new tag, and a re-pin in the cluster
repo — see `wip/iaac-talos-flux-cluster/PROMOTING-RISINGWAVE.md`. Not a platform PR.

**That is the useful property of `check-helmrelease-truth.sh`: it audits the CLUSTER, not a
repository.** It found a release no platform PR could have reached. A repo-side linter would
have reported the platform clean and been right about the wrong question.

Also visible: `arc-systems/arc`, `arc-runners/risingwave-pipeline` and `octopus/octopusworker`
exist on the `op-qa` branch and were patched by #152, but **none of them is present on the
cluster** — the check lists 19 HelmReleases against more files in Git. Either they are not
enumerated in a Kustomization, or they belong elsewhere. `arc-runners/risingwave-pipeline` is
the RisingWave CI runner, so this matters to the dev→QA pipeline question and is worth
resolving before that conversation. Not chased today.

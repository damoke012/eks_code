# RisingWave on-prem: alerts to build

Every alert below is derived from a failure that **actually happened** on these clusters, with
the date and the damage. Nothing here is speculative best practice. Where an incident ran for
weeks with every dashboard green, that is stated — those are the ones worth building first.

Scope: `op-usxpress-dev`, `-qa`, `-prod`, namespaces `risingwave` and `app-risingwave`, plus
the GitHub Actions pipeline that deploys into them.

---

## 0. Preconditions — build these first or nothing below fires

| # | Precondition | State |
|---|---|---|
| P1 | **Alertmanager exists and delivers.** dev had 40 rules and 54 firing alerts with no Alertmanager at all; the Flux rules were dead for four separate reasons in series. Fixed dev + QA 2026-08-24. **Prod still pending.** | prod OPEN |
| P2 | **RisingWave is actually scraped.** QA's RW had no PodMonitors — dev's RW was scraped by RisingWave's *own* bundled Prometheus, so dropping that stack left nothing scraping it. Ports: meta **1250**, frontend **8080**, compute **1222**, compactor **1260**. | verify per cluster |
| P3 | **The component label scheme is version-dependent** — `risingwave/component` on the current operator, `risingwave.risingwavelabs.com/component` on others. Gate on *targets UP in Prometheus*, not on the manifest existing. | verify per cluster |

⚠️ P2 and P3 are why several alerts below are marked **signal unconfirmed**: the rule is right,
but the exact metric name must be read off the live `/metrics` endpoint before it is written.
Do not copy a metric name from this document into a PrometheusRule without checking it.

---

## 1. Tier one — each of these would have caught a real outage

### A1. Pod missing IRSA credentials its ServiceAccount promises
**Caught nothing for 54 days.** `risingwave-compactor-default` on dev ran 88 days with no
`AWS_ROLE_ARN` and no `AWS_WEB_IDENTITY_TOKEN_FILE`. `pod-identity-webhook` has
`failurePolicy: Ignore`, so a pod created while the webhook is unreachable starts with no
credentials and **nothing is logged, rejected or alerted**. Compaction died, no epoch could
commit, every `CREATE TABLE` hung forever — and all four workers reported RUNNING throughout.
Found 2026-09-15 by a test canary, not by monitoring.

- **Signal:** any pod whose ServiceAccount carries `eks.amazonaws.com/role-arn` but whose spec
  has no `AWS_WEB_IDENTITY_TOKEN_FILE` env var.
- **Best mechanism: a Kyverno policy**, not a Prometheus rule — Kyverno is already on these
  clusters, and it can both *audit* existing pods and *warn* at admission. A metric-based
  version needs a custom exporter.
- **Severity:** high. Silent, total, and only visible when someone tries to write.
- **Fleet-wide, not RW-specific.** Every IRSA consumer has this exposure.

### A2. RisingWave DDL stuck
`rw_catalog.rw_ddl_progress` had a `CREATE TABLE` at **0.0% since 2026-08-28** — 18 days —
that nobody noticed, plus ours from the same afternoon. A foreground DDL that never completes
means the cluster cannot accept new pipeline objects at all.

- **Signal:** any row in `rw_ddl_progress` whose `initialized_at` is older than ~15 minutes.
- **Mechanism:** no Prometheus metric exists for this. Needs a small CronJob that runs the
  query over pg-wire and exposes a gauge, or pushes to the Pushgateway that already runs in
  `risingwave-2` on dev.
- **Severity:** high. This is the single clearest "the pipeline cannot deploy" signal.

### A3. Hummock compaction stalled / L0 backlog
During the dev outage: **Level 0 held 359 SSTs while levels 1–6 were empty**. That shape means
compaction is dead and barriers cannot checkpoint.

- **Signal:** L0 SST count sustained above a threshold, or L0 non-zero while L1–L6 are all zero
  for more than ~30 minutes. The meta node logs this every ~10 minutes; confirm the
  corresponding metric name on the meta `/metrics` endpoint (port 1250). **Signal unconfirmed.**
- **Severity:** high, and it precedes every symptom users notice.

### A4. Object-store errors from any RisingWave component
The compactor logged `risingwave_object_store::object: read failed error=Timeout error` every
few hundred milliseconds for weeks. Nothing consumed those logs.

- **Signal:** rate of object-store error log lines, or the component's own S3 error counter, in
  compactor / compute / meta. **Signal unconfirmed** — check for an
  `object_store` error counter before falling back to a log-based rule.
- **Severity:** high. Note it is a *timeout*, not AccessDenied — do not scope the rule to
  permission errors only.

### A5. Epoch / barrier not advancing
Compute logged `wait_for_epoch ... elapsed=4645511s` — **53.8 days on a single wait**, exactly
the age of the pod. An epoch that never advances means nothing is being processed even though
every object still exists in the catalog.

- **Signal:** max epoch wait duration, or the current epoch failing to increase over a window.
  **Signal unconfirmed.**
- **Severity:** critical. This is the closest thing to "the database is silently frozen".
- ⚠️ Tim's four Brand objects sat frozen at a July epoch for 54 days and still appeared in the
  catalog. **Catalog presence is not liveness** — that is precisely why this alert is needed.

### A6. ExternalSecret green but the value does not work
Bit us twice: Wiz, and QA etcd-backup. `SecretSynced` proves the sync ran, not that the content
is usable. Worse, a `SecretSyncedError` still writes the keys it *could* resolve, so the pod
dies at container creation with **RESTARTS 0** — invisible to every restart-based alert.

- **Signal, two rules:**
  1. `ExternalSecret` in `SecretSyncedError` for > 10 minutes.
  2. Pods stuck in `ContainerCreating` / `CreateContainerConfigError` for > 10 minutes —
     `kube_pod_container_status_waiting_reason`. This is the one that catches the silent case.
- **Severity:** high. QA ran a three-week-old image behind a merged promotion because of this.

### A7. RisingWave licence expiry
The licence expired **2026-07-31** and the console kept running only because it had not
restarted since 17 July — any drain would have killed it. The failure also leaves
`rw-bootstrap-service-accounts` in permanent CrashLoopBackOff.

- **Signal:** decode the JWT `exp` from the licence secret and alert at 30 and 7 days. A CronJob
  and a gauge; there is no built-in metric.
- **Also alert on the placeholder**: all environments currently hold the literal
  `PLACEHOLDER_INJECT_REAL_LICENSE`. A real licence is a compact JWT — three dot-separated
  parts beginning `eyJ`. Alert if the value is not one.
- **Severity:** medium, but the blast radius is unknown until someone confirms whether any
  data-plane feature is licence-gated.

---

## 2. Tier two — known failure modes, not yet an outage on RW

### B1. RisingWave component restart storms
dev meta showed **87 restarts**, compute worker id **1941** (worker ids increment per
registration, so roughly a thousand re-registrations). QA showed meta 238 / compute 310 /
frontend 276 / compactor 313 restarts over two days, and **the cause was never established**.

- **Signal:** `increase(kube_pod_container_status_restarts_total{namespace="risingwave"}[1h]) > 3`.
- **Severity:** medium. Also a reminder to investigate the QA restart episode before that shape
  reaches prod.

### B2. Source not consuming / materialized view not advancing
The failure users actually report is "the data is empty". Causes seen: a Kafka service account
that can read topics but **cannot join a consumer group** (authz, not a bad key), and sources
frozen behind a stalled epoch.

- **Signal:** source offset lag, or MV row count flat while the upstream topic advances.
  **Signal unconfirmed** — needs the RW source metrics plus Kafka lag from the Confluent side.
- **Severity:** high for anything the business reads.

### B3. Ghostunnel serving nothing
`ghostunnel-rw-postgres` runs `--listen=:4567` while its Service maps **5432** — so
`rw-postgres.op-*.usxpress.io` has resolved and served nothing since 2026-06-01, on **both**
dev and QA. Invisible because the readinessProbe targets ghostunnel's own status listener on
9090, which cannot see the data port. Both pods report `READY true, 0 restarts`.

- **Signal:** a blackbox TCP probe against the **data** port of every tunnel, from outside the
  pod. Not a readiness probe — the readiness probe is the thing that lied.
- **Severity:** high, and it is still open (INFRA-1654).
- **Generalise it:** any probe that checks a different port from the one serving traffic is
  decorative. Audit the others.

### B4. Postgres credential drift
QA's Postgres was initialised 2026-08-11, the secret rotated 2026-08-12, and the database never
learned the new password. Fixed 2026-08-20.

- **Signal:** a periodic authenticated connection using the credential *from the secret*. A
  connection test that uses a cached or in-pod credential proves nothing.
- **Severity:** medium.

### B5. Velero backups for the RisingWave namespace
A kustomize `namespace:` transformer rewrote a Velero Schedule's namespace; Velero only watches
its own namespace, so the Schedule was created, reported no error, and **never backed anything
up**.

- **Signal:** last successful backup age per schedule, and an alert when a *named expected*
  schedule is absent. The absence case is the one that bit us.
- **Severity:** medium.

### B7. Console metrics datasource unreachable
QA's console pointed at `prometheus-server.monitoring.svc.cluster.local:9090` for weeks — a
namespace that **does not exist on that cluster**. The only record was a `TODO: confirm` in the
config, and a PR nearly deleted the TODO while leaving the address wrong (iaac-risingwave-onprem
#36, caught in review 2026-09-15). Corrected to
`prometheus-stack-kube-prom-prometheus.prometheus.svc.cluster.local:9090`.

- **Signal:** resolve and probe every datasource address the console config declares, per
  cluster. A config value naming a non-existent Service or namespace should fail loudly.
- **Severity:** low for data, high for trust — a console showing no metrics is usually read as
  "the cluster is idle".
- **Generalise:** any hardcoded cross-namespace address in a ConfigMap is worth a resolve check.
  The addresses differ per cluster and get copied between environments.

### B6. Certificate expiry
QA RW's routes are served by the `*.op-qa.usxpress.io` wildcard; the two per-host Certificates
in `risingwave-routes` are issued but unused.

- **Signal:** `certmanager_certificate_expiration_timestamp_seconds` under 21 days.
- **Severity:** medium. Cheap and standard.

---

## 3. Tier three — the delivery pipeline, not the database

These are GitHub Actions and GitOps failures. They do not need Prometheus; most are a scheduled
API query, and several were fixed in `risingwave-pipeline` on 2026-09-15 by adding the control
rather than the alert.

### C1. A pipeline run that applies nothing but reports success
**Fixed in code 2026-09-15** — `approve` and `execute` now skip when the change set is empty,
and change detection fails closed. Keep an alert anyway for the inverse: a run that reports
success while the apply step was skipped for any *other* reason.

### C2. A control that quietly disappears
`pipeline-approval` had `protection_rules: []` — the approval job printed "approved" and
proceeded in 3 seconds. A gate can be removed by anyone with repo admin, silently.

- **Signal:** scheduled check that each protected environment still has required reviewers, and
  that `prevent_self_review` matches the intended posture. **Currently `false` deliberately and
  temporarily** — the alert should assert the *intended* value, whatever it is at the time.
- **Severity:** high for prod.

### C3. Workflow branches drifting apart
A workflow file runs as it exists **on the branch receiving the push**, so a fix merged to
`master` does nothing for `qa` until it is copied. Six sync PRs were needed in one afternoon.

- **Signal:** scheduled diff of `.github/workflows/pipeline.yaml` across `master`, `qa`, `dev`;
  alert on any difference.
- **Severity:** medium, and it removes an entire class of "fixed but not really".

### C4. GitOps layer stale
GitRepository → Kustomization → HelmRelease → Pod: each reports Ready while the next is behind.
`lastAppliedRevision` is not the live state.

- **Signal:** Flux `Kustomization`/`HelmRelease` not-Ready for > 15 minutes, **and** a reconcile
  whose `lastAppliedRevision` trails the GitRepository revision.
- **Severity:** medium.

### C5. A failed Argo sync hook wedging every later sync
A wedged sync-hook Job makes the next sync return in 0s replaying the OLD failure. Compare
`startedAt` with `finishedAt` before believing a failed sync is current.

- **Signal:** Argo Application `OutOfSync`/`Degraded` > 30 minutes, plus sync duration ~0s with
  a failure.
- **Severity:** medium.

### C6. A Flux Kustomization stuck in dry-run failure
On 2026-09-15 `risingwave-onprem` on op-usxpress-qa failed its server-side-apply dry-run on
every reconcile for ~4 hours — `spec.strategy.rollingUpdate: Forbidden: may not be specified
when strategy type is 'Recreate'` — because the live Deployment carried a field the manifest
had stopped mentioning. **A dry-run failure fails the whole Kustomization**, so `risingwave-onprem`
and `risingwave-operator` were both frozen while the merged PR looked done. Nobody was told;
it was found by a human looking at QA.

- **Signal:** `gotk_reconcile_condition{type="Ready",status="False"}` on any `Kustomization`
  for > 15 minutes. Distinct from C4: C4 is a stale revision, this is a reconcile that is
  actively erroring. Route the condition **message** into the alert — `dry-run failed (Invalid)`
  names the resource and the field, which is the whole diagnosis.
- **Severity:** high. This is the alert that turns "merged" into "applied", and its absence is
  why a four-hour outage of the delivery path went unnoticed on a cluster we look at daily.
- **Status 2026-09-15: NOT BUILDABLE AS AN ALERT YET.** Checked op-usxpress-qa —
  `kubectl get alertmanagers.monitoring.coreos.com -A` returns **No resources found**, and
  none of its 45 PrometheusRules covers Flux (`gotk_reconcile_condition`) at all. So this did
  not fire and reach nobody; **there was nothing to fire**. Both halves are missing. Adding a
  rule before P1 lands would put alert #46 into a system with no receiver.
- **Interim detector, working today:** `scripts/flux-kustomization-health.sh --cluster op-qa`,
  in `weekly-maintenance.sh` section 9. It prints the Ready condition message, exits 3 on
  not-Ready and 7 when a cluster cannot be assessed, and refuses to report health from an
  unreachable cluster, zero rows, or its own dead parser. Self-test:
  `scripts/flux-kustomization-health.test.sh`, 8 cases, both directions.
  Weekly is a poor substitute for 15 minutes — it is the difference between "caught within a
  week" and "caught when a human happens to look", which is what actually happened here.
- **Note:** C4's *stale revision* check would NOT have fired here — `lastAppliedRevision` sat
  at the previous good sha and the GitRepository had moved, so a trailing-revision rule needs
  the not-Ready condition alongside it to be useful.

---

## 4. Do not alert on these — they are the signals that misled us

| Signal | Why it lies |
|---|---|
| Pod `Running` / `1/1` | The dev compactor was 1/1 for 88 days with no credentials. |
| `ExternalSecret: SecretSynced` | Proves the sync ran, not that the value works. |
| Container restart count | The ESO partial-secret failure dies at container creation with RESTARTS **0**. |
| A green workflow run | Its executor steps may have been skipped. That exact shape was briefly mistaken for proof. |
| Flux/Argo `Ready` | Ready describes that layer, not the one below it. |
| `rw_catalog` object presence | Tim's Brand objects existed throughout a 54-day freeze. |
| A readinessProbe on a management port | ghostunnel's 9090 probe cannot see the 5432 data port. |
| An empty query result | Three times in one day an empty result was an expired token or a wrong kubeconfig, not an absence. |
| A merged PR | #36 merged and was **never applied** for 4 hours; QA kept running the pre-merge pod. Merged is not deployed. |
| `Applied revision: <sha>` | A claim about the apply attempt. Finish at the **pod**: its age, and a field only the new template has. |

**The pattern behind all of them:** a true success report about the step *next to* the one that
matters. Prefer alerts that measure the property the user cares about — can a query run, can an
object be created, did a row arrive — over alerts on components being up.

---

## 5. Suggested build order

1. **P1 prod Alertmanager**, then **P2/P3 scraping.** Nothing else matters until these exist.
2. **A1 (IRSA)** — fleet-wide, Kyverno, catches the worst class: silent and total.
3. **A2, A3, A5** — the three that together mean "RisingWave is frozen".
4. **A6** — two rules, standard metrics, catches a recurring one.
5. **C2, C3** — cheap scheduled API checks, protect the controls built on 2026-09-15.
6. Everything else as capacity allows.

## 6. Open questions before building

- Which Prometheus scrapes RisingWave on each cluster? dev's RW metrics and the platform stack
  have been tangled — and the Prometheus in dev's `risingwave-2` namespace is itself
  CrashLoopBackOff with 1500+ restarts, so confirm which instance is authoritative.
- Does prod have Alertmanager yet, and where do its notifications go?
- Who receives RisingWave alerts — the platform team, Tim, or Idris? An alert with no owner is a
  dashboard.
- For A2 and A7, is a CronJob-plus-Pushgateway acceptable, or should a small exporter be built?

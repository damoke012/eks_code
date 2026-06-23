# PSA `enforce: restricted` blocks pods missing seccompProfile

**Category**: 04-secrets-credentials (PSA / pod security)
**First seen**: 2026-06-23 op-usxpress-dev etcd-backup CronJob
**Severity**: silent — Job stays Running forever, no pods spawn

## Symptom

A Job or CronJob in a `pod-security.kubernetes.io/enforce: restricted` namespace stays `STATUS=Running` with `COMPLETIONS=0/1` for hours. No pods appear under `kubectl get pods -l job-name=...`.

`kubectl describe job <name>`:

```
Events:
  Type     Reason        Age    From            Message
  Warning  FailedCreate  5m33s  job-controller  Error creating: pods "<name>" is forbidden:
                                                violates PodSecurity "restricted:latest":
                                                seccompProfile (pod or container "<container>" must set
                                                securityContext.seccompProfile.type to
                                                "RuntimeDefault" or "Localhost")
  Warning  FailedCreate  5m32s  job-controller  Error creating: pods "<name>" is forbidden: ...
  Warning  FailedCreate  5m30s  ...   ... (job-controller keeps retrying)
```

The Job retries up to `backoffLimit` then `BackoffLimitExceeded`. CronJob silently fails every scheduled run. The namespace's `kubectl get jobs` shows multiple `Failed` entries with no other clue:

```
NAME                           STATUS  COMPLETIONS  DURATION  AGE
etcd-snapshot-to-s3-29703797   Failed  0/1          4h38m     4h38m
etcd-snapshot-to-s3-29703857   Failed  0/1          3h38m     3h38m
```

You don't notice the gap until you query for ACTUAL backups in S3 and find none.

## Why

`pod-security.kubernetes.io/enforce: restricted` requires ALL of:

| Field | Required value | Level |
|---|---|---|
| `securityContext.seccompProfile.type` | `RuntimeDefault` or `Localhost` | pod OR container |
| `containers[*].securityContext.allowPrivilegeEscalation` | `false` | container |
| `containers[*].securityContext.runAsNonRoot` | `true` | container |
| `containers[*].securityContext.runAsUser` | non-zero (or unset if image's default user is non-root) | container |
| `containers[*].securityContext.capabilities.drop` | must include `ALL` | container |

The `seccompProfile.type` is often missed because it's the only field that's most cleanly set at pod level (one place, applies to all containers).

Helm charts that target restricted PSA usually set these in the chart values' `podSecurityContext` block — hand-rolled CronJobs/Jobs and `kubectl create job --from=cronjob/...` triggers are where the gap lives.

## Fix

Set `seccompProfile` at the **pod level** (applies to all containers):

```yaml
spec:
  template:
    spec:
      securityContext:
        seccompProfile:
          type: RuntimeDefault       # required
      containers:
      - name: <name>
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          runAsUser: 1000
          capabilities:
            drop: ["ALL"]
```

For Helm-managed apps: check chart values for `podSecurityContext.seccompProfile.type`. Many charts default to `Unconfined` or omit it entirely.

## Detection

Before deploying a hand-rolled pod-spawning resource to a restricted-PSA namespace:

```bash
# Server-side dry-run reveals PSA violations
kubectl -n <ns> create -f <manifest> --dry-run=server 2>&1 | grep -i violat
```

After deployment:

```bash
# Pod count for a Job — should be > 0
kubectl -n <ns> get pods -l job-name=<job-name>

# If no pods + Job age > 1 min:
kubectl -n <ns> describe job <job-name> | grep -A 5 Events:
# Look for "violates PodSecurity"
```

For CronJobs — there's no obvious failure path. Set up monitoring:

```yaml
# PrometheusRule
- alert: CronJobNeverSpawnsPod
  expr: kube_job_status_failed{job_name=~"<your-cronjob>.*"} > 0 and on(namespace, job_name) kube_pod_info offset 1m == 0
  for: 15m
  annotations:
    summary: "CronJob {{ $labels.job_name }} spawned no pods — likely PSA violation"
```

Or just check periodically:

```bash
kubectl -n <ns> get jobs --sort-by='.metadata.creationTimestamp' | tail -5
# If all recent jobs show Failed with 0 completions, investigate PSA
```

## Recovery

After fixing the manifest + redeploying:

```bash
# Delete any zombie Jobs from before the fix
kubectl -n <ns> delete jobs --field-selector status.successful=0

# Trigger a manual CronJob run to validate
kubectl -n <ns> create job --from=cronjob/<name> <name>-manual-test
sleep 60
kubectl -n <ns> get pods -l job-name=<name>-manual-test
# Should be Running or Completed, NOT 0 pods
```

## How to apply to QA / PROD

- Pre-flight check: any restricted-PSA namespace + hand-rolled Job/CronJob spec → confirm seccompProfile is set
- Add `kubectl --dry-run=server` to the PR pipeline for those namespaces
- For Helm charts, prefer chart values that target restricted by default (many community charts ship with baseline only)

## Related

- Reference incident: op-usxpress-dev 2026-06-23 etcd-backup CronJob — 4 scheduled runs failed silently, manual trigger retried 10 times, before we realized
- Kubernetes docs: [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [`talosctl-image-distroless.md`](./talosctl-image-distroless.md) — the OTHER reason that same etcd-backup CronJob had pods fail to start (post-PSA fix)

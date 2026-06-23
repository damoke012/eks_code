# Velero PVC backup fails with `sts..amazonaws.com` DNS error

**Category**: 03-network-irsa
**First seen**: 2026-06-23 op-usxpress-dev
**Severity**: silent partial failure — Velero metadata succeeds, PVC content doesn't
**Affected versions**: vmware-tanzu/velero chart 8.x (1.15.x app); likely all 1.x

## Symptom

`velero backup create ... --wait` returns `Phase: PartiallyFailed`. The backup metadata writes to S3 (resource-list, logs, json files) but every pod volume gets skipped:

```
resource: /pods name: /<pod-name>
message: /Skip pod volume <vol> error: /failed to wait BackupRepository,
errored early: backup repository is not ready:
error to get repo options: error to get repo credentials:
error get s3 credentials: failed to refresh cached credentials,
failed to retrieve credentials, operation error STS:
AssumeRoleWithWebIdentity, https response error StatusCode: 0,
RequestID: , request send failed,
Post "https://sts..amazonaws.com/":
dial tcp: lookup sts..amazonaws.com: no such host
```

The telltale: **double dot `sts..amazonaws.com`**.

`BackupRepository` stays at `phase: NotReady`.

## Why

The Velero **main pod** uses BSL `spec.config.region` for some operations. So metadata writes work — they go through the chart-managed BSL flow with explicit region.

The **node-agent DaemonSet** runs Kopia (the file-system backup engine), which makes its OWN STS `AssumeRoleWithWebIdentity` call to assume the IRSA role. That code path reads `AWS_REGION` (or `AWS_DEFAULT_REGION`) from process env — not from BSL.

When AWS_REGION is unset, AWS SDK constructs the STS endpoint as `sts.<region>.amazonaws.com`. With empty region, the URL becomes `sts..amazonaws.com` and DNS resolution fails → `no such host`.

## Fix

Set `AWS_REGION` via the Helm chart's `configuration.extraEnvVars` (this flows to BOTH the velero deployment AND the node-agent DS via chart template):

```yaml
spec:
  values:
    configuration:
      extraEnvVars:
        AWS_REGION: us-east-2     # map form; chart iterates with range $k, $v
```

⚠️ **Do NOT also set `nodeAgent.extraEnvVars` with the same key.** Chart 8.x renders both blocks on node-agent DS — same key in both = duplicate env entries → server-side apply rejects → silent helm rollback chain. See [`velero-chart-extra-env-duplicate.md`](./velero-chart-extra-env-duplicate.md).

After helm upgrade succeeds:

```bash
# Confirm AWS_REGION on both
kubectl -n velero get deploy velero -o jsonpath='{.spec.template.spec.containers[0].env}' | jq | grep -B 1 -A 1 AWS_REGION
kubectl -n velero get ds node-agent -o jsonpath='{.spec.template.spec.containers[0].env}' | jq | grep -B 1 -A 1 AWS_REGION

# Force fresh BackupRepository
kubectl -n velero delete backuprepository --all

# Re-test
velero backup create test-backup --include-namespaces <small-ns> --wait
velero backup describe test-backup | grep Phase
# Expected: Completed

aws s3 ls s3://<velero-bucket>/kopia/ --recursive --human-readable
# Expected: chunk files sized in MB (not Bytes)
```

## Detection

Smoke test on every new Velero install, before assuming PVC backups work:

```bash
# 1. Verify env var landed
kubectl -n velero get ds node-agent -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="AWS_REGION")].value}'; echo
# Expected: us-east-2 (or your region)

# 2. Verify BackupRepository can be created and goes Ready
kubectl -n velero get backuprepository
# All should be phase: Ready (not NotReady)

# 3. Velero metadata-only backup succeeds even without this fix — DO NOT use as a green signal
```

## Recovery (silent rollback chain)

If `helm history velero -n velero` shows status=failed entries followed by status=superseded "Rollback to N", the cluster's Velero is currently in pre-change state — even though Flux says "applied revision X.Y.Z". Fix the values, push, reconcile:

```bash
flux -n flux-system reconcile source git infra
flux -n velero reconcile helmrelease velero --with-source
helm -n velero history velero | tail -5   # confirm latest revision is "deployed", not "failed"/"Rollback"
```

## Related

- [`velero-chart-extra-env-duplicate.md`](./velero-chart-extra-env-duplicate.md) — why ONLY configuration.extraEnvVars
- [`psa-restricted-seccomp-required.md`](./psa-restricted-seccomp-required.md) — adjacent hand-rolled CronJob PSA gotcha
- Reference incident: op-usxpress-dev 2026-06-23 PR #59 → PR #60 (took 3 PRs to land cleanly)

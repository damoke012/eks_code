# Velero HelmRelease — fix for bitnami legacy image 404

## Why

After our Velero deployment was scaffolded, the Helm chart's CRD-upgrade hook Job pulls `docker.io/bitnami/kubectl:1.32`. Bitnami removed legacy versioned tags as part of the 2025 Secure Images migration. The tag returns 404, init container goes into `ImagePullBackOff`, the Job never completes, the HelmRelease never installs.

Per memory `[feedback_bitnami_legacy_migration.md]`: switch to `docker.io/bitnamilegacy/*` for legacy tags.

## Fix

Add to `infrastructure/velero/helmrelease.yaml` under `spec.values.kubectl`:

```yaml
spec:
  values:
    # ... existing values ...
    kubectl:
      image:
        repository: docker.io/bitnamilegacy/kubectl
        tag: "1.32"
        pullPolicy: IfNotPresent
    # ... rest of existing values ...
```

This is appended to the existing values block (between the existing initContainers and serviceAccount sections, or anywhere in values — order doesn't matter to Helm).

## Live application

Once committed + merged, Flux reconciles HelmRelease → Helm renders chart with new kubectl image → Job retries with bitnamilegacy image → Job succeeds → Velero installs.

**This won't take effect tonight** because Velero Kustomization is currently SUSPENDED (we suspended it last session pending IAM/S3 from PR-P). When we un-suspend AFTER PR-P + AWS SM seed, Velero should install cleanly.

## Reference

- Memory: `feedback_bitnami_legacy_migration.md`
- Memory: `feedback_bitnami_chart_np_ambient_hbone.md`
- Bitnami migration: https://github.com/bitnami/containers/issues/83267

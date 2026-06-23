# Velero chart silent helm rollback — duplicate env on node-agent DS

**Category**: 03-network-irsa
**First seen**: 2026-06-23 op-usxpress-dev PR #59 → #60
**Severity**: silent failure (Flux reports "applied revision X" but Helm has rolled back)
**Affected versions**: vmware-tanzu/velero chart 8.x (verified 8.7.2)

## Symptom

Helm upgrade FAILS but cluster keeps running on old version. Flux's HelmRelease shows `Ready=True` with the new chart revision applied. But the rendered Deployment/DS does not contain the env var you set in values.

`helm history velero -n velero`:

```
REVISION  UPDATED                  STATUS      CHART          DESCRIPTION
7         Tue Jun 23 20:14:44 2026 failed      velero-8.7.2   Upgrade "velero" failed: server-side apply failed
                                                              for object velero/node-agent apps/v1, Kind=DaemonSet:
                                                              failed to create typed patch object: 
                                                              .spec.template.spec.containers[name="node-agent"].env:
                                                              duplicate entries for key [name="AWS_REGION"]
8         Tue Jun 23 20:14:56 2026 superseded  velero-8.7.2   Rollback to 6
9         Tue Jun 23 20:15:55 2026 failed      velero-8.7.2   <same error>
10        Tue Jun 23 20:16:07 2026 superseded  velero-8.7.2   Rollback to 8
```

Without inspecting `helm history`, the gap is invisible — `flux get hr` shows everything green.

## Why

Chart 8.x `templates/node-agent-daemonset.yaml` renders env vars from BOTH:
- `.Values.configuration.extraEnvVars` (around line 162)
- `.Values.nodeAgent.extraEnvVars` (around line 177)

If both maps contain `AWS_REGION`, the rendered DS has TWO entries named `AWS_REGION` in `spec.template.spec.containers[*].env`. Server-side apply rejects this — it requires unique keys.

The `configuration.extraEnvVars` block ALSO renders on the Velero deployment (`templates/deployment.yaml` line 257). So that single block covers BOTH the deploy and the node-agent DS.

`nodeAgent.extraEnvVars` is for env vars that ONLY the node-agent needs (and that don't overlap with `configuration.extraEnvVars`).

## Fix

Single MAP block under `configuration.extraEnvVars`:

```yaml
spec:
  values:
    configuration:
      extraEnvVars:
        AWS_REGION: us-east-2
    # nodeAgent: ...do NOT add extraEnvVars here for any key already in configuration
```

## Detection

After any Velero HelmRelease values change:

```bash
helm -n velero history velero | tail -5
# Look for status=failed entries OR "Rollback to N" — if present, the upgrade silently rolled back

# Confirm the env var actually landed in the rendered manifest
helm -n velero get manifest velero | grep -B 1 -A 1 AWS_REGION
# Should appear in BOTH the velero Deployment and the node-agent DaemonSet env blocks
```

## Recovery

Remove the duplicate key. If you need different values per workload, use distinct keys:

```yaml
configuration:
  extraEnvVars:
    AWS_REGION: us-east-2          # both pods
nodeAgent:
  extraEnvVars:
    NODE_AGENT_ONLY_VAR: value     # node-agent only
```

Force re-reconcile after merging the fix:

```bash
flux -n flux-system reconcile source git infra
flux -n velero reconcile helmrelease velero --with-source
helm -n velero history velero | tail -3   # confirm "deployed" status
```

## How to apply to QA / PROD

- Bake the `configuration.extraEnvVars` block into the chart values BEFORE first install. Don't accumulate per-cluster ceremonies.
- If you're adding a new env var and the rendered manifest doesn't show it, ALWAYS check `helm history` first — Flux+helm-controller can hide silent rollbacks.

## Related

- [`velero-kopia-aws-region-required.md`](./velero-kopia-aws-region-required.md) — why AWS_REGION is needed in the first place (the original problem this fix addresses)
- Reference: vmware-tanzu/helm-charts `templates/node-agent-daemonset.yaml` lines 162 + 177 (chart 8.7.2)
- Reference: op-usxpress-dev PRs #59, #60 — 2026-06-23

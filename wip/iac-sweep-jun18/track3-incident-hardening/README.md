# Track 3 — Incident hardening (the 2026-06-17 + 2026-06-18 lessons)

**Why this exists:** the OOM cascade + cert cascade both happened without alerts. We were lucky in both cases (caught by Idris pings within hours). These rules + capacity bump close the detection gap.

## Files

| File | Purpose | Target repo / path |
|---|---|---|
| `prometheusrule-cp-memory.yaml` | Alerts on CP memory < 1 GB (warn) / < 500 MB (crit + page) | `iaac-talos-flux-platform/infrastructure/prometheus-rules/` |
| `prometheusrule-etcd-peers.yaml` | etcd peer unreachable, leader storms, slow fsync | `iaac-talos-flux-platform/infrastructure/prometheus-rules/` |
| `cronjob-talosconfig-backup.yaml` | Daily snapshot of tfstate to versioned S3 path | `iaac-talos-flux-platform/infrastructure/talos-backup/` (new folder) |
| `worker-ram-bump.tf.patch` | Bump worker_memory_mb default 4096 → 8192 | `iaac-talos/deploy/terraform/variables.tf` |

## PR sequence

1. PR `prometheusrule-cp-memory.yaml` first — pure detection
2. PR `prometheusrule-etcd-peers.yaml` second — pure detection
3. PR `worker-ram-bump.tf.patch` to iaac-talos — **CAUTION**: this triggers a worker VM power cycle when applied via Octopus. Coordinate with Tim before Octopus apply. Run `/onprem-safety` first.
4. PR `cronjob-talosconfig-backup.yaml` — requires IRSA role first. See "IRSA setup" below.

## IRSA setup (one-time, before CronJob can deploy)

```hcl
# Add to iaac-talos terraform:
resource "aws_iam_role" "talosconfig_backup" {
  name = "talosconfig-backup-op-usxpress-dev"
  assume_role_policy = data.aws_iam_policy_document.talosconfig_backup_assume.json
}

resource "aws_iam_role_policy" "talosconfig_backup" {
  role = aws_iam_role.talosconfig_backup.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject"]
      Resource = "arn:aws:s3:::lazy-tf-state-65v583i6my68y6x9/talosconfig-snapshots/*"
    }]
  })
}
```

Then drop the role ARN into the CronJob's `eks.amazonaws.com/role-arn` annotation (currently `<FILL_IN_IRSA_ARN>`).

## Validation after merge

```bash
# PromRules loaded
kubectl -n monitoring get prometheusrule control-plane-memory etcd-cluster-health

# Worker RAM bumped (after Octopus apply)
for ip in 10.10.82.21 10.10.82.22 10.10.82.26 10.10.82.27 10.10.82.28 10.10.82.178 10.10.82.180; do
  echo -n "$ip: "
  talosctl --nodes $ip --endpoints $ip memory | tail -1 | awk '{print $2 " MB total"}'
done
# Each should show ~7900-8000 MB

# Talosconfig backup
kubectl -n kube-system get cronjob talosconfig-backup
kubectl -n kube-system create job --from=cronjob/talosconfig-backup talosconfig-backup-manual
kubectl -n kube-system logs job/talosconfig-backup-manual
# Should show "Snapshot written: s3://..."
aws s3 ls s3://lazy-tf-state-65v583i6my68y6x9/talosconfig-snapshots/op-usxpress-dev/
```

## Risks / caveats

- **Worker RAM bump triggers VM power-cycle (not hot-add).** Coordinate with Tim — each worker reboot interrupts hostPort 4567/5432 traffic on that worker for ~5 min.
- **PromRules require kube-state-metrics + node-exporter + the kube-prometheus stack** to be installed and labeled correctly. The `prometheus: kube-prometheus` selector matches the existing Prometheus instance on op-dev — verify by checking what Prometheus already picks up.
- **etcd metrics endpoint**: Talos may not expose etcd's Prometheus endpoint to scrape directly. Verify with `talosctl --nodes <CP> --endpoints <CP> service etcd` and the corresponding etcd `--listen-metrics-urls` config. If not exposed, the etcd rules silently won't fire — add a follow-up ticket to enable it via Talos machine config.

## Related lessons codified

- [[incident_2026_06_17_cp_oom_cascade]]
- [[incident_2026_06_18_cilium_orphan_cert_cascade]]
- `/onprem-safety` Rule 2 (CP capacity) + Rule 4 (etcd quorum protection) + Rule 6 (talosconfig recovery path)

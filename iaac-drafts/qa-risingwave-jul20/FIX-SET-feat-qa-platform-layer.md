# Fix set — `variant-inc/iaac-risingwave-onprem` branch `feat/qa-platform-layer`

Review date 2026-07-22. Branch is structurally sound (ExternalSecrets throughout,
`ceph-block`, `pool: platform` everywhere, RW's own Prometheus/Grafana correctly
omitted, image pinned `v2.8.2`). Six defects block rollout.

Apply **one block at a time** — multi-block heredoc pastes have been mangled before.

---

## F1 — Velero Schedule lands in the wrong namespace (CONFIRMED)

`kustomization.yaml` sets `namespace: risingwave`, which rewrites `metadata.namespace`
on every resource. Rendered output confirms the Schedule gets `namespace: risingwave`.
Velero's controller only watches its own namespace, so the Schedule is created, reports
no error, and **never takes a backup** — same green-object/no-artifact shape as INFRA-1623.

There is no clean per-resource exemption from kustomize's namespace transformer, and the
Schedule is platform-stack config anyway. **Doke takes it into
`iaac-talos-flux-platform` `op-qa` alongside the rest of Velero.**

Idris: delete `velero-schedule.yaml` and its `resources:` entry.

## F2 — Terraform backend points at dev's state (HIGHEST DAMAGE)

`terraform/main.tf` hardcodes `key = "iaac/risingwave/op-usxpress-dev.tfstate"`. A QA
apply would read dev's state and reconcile dev's live bucket and IAM role toward QA's
tfvars.

Blank the defaults so a missing `-backend-config` fails loudly instead of silently
resolving to dev:

```hcl
  backend "s3" {
    # Values supplied per environment via -backend-config.
    #   dev: terraform init -backend-config=backend-dev.hcl
    #   qa:  terraform init -backend-config=backend-qa.hcl
    # Intentionally empty: a missing -backend-config must fail, not default to dev.
  }
```

Then add `terraform/backend-dev.hcl` (preserving today's values) and
`terraform/backend-qa.hcl`:

```hcl
bucket         = "lazy-tf-state-425rbol87rmn6c7m"
key            = "iaac/risingwave/op-usxpress-qa.tfstate"
region         = "us-east-2"
dynamodb_table = "lazy_tf_state"
encrypt        = true
```

⚠️ Confirm that bucket and DynamoDB table exist **in QA account 527101283767** before
relying on them — they're the iaac-talos QA values. Also confirm how `octo.yaml` /
`deploy/` pass `-backend-config`; if Octopus runs a bare `terraform init`, F2 is not
fixed by these files alone.

## F3 — `terraform/op-usxpress-qa.tfvars` missing

```hcl
cluster_name     = "op-usxpress-qa"
region           = "us-east-2"
aws_profile      = "usx-qa"
oidc_issuer      = "d2t7d36wmf0hbm.cloudfront.net"
namespace        = "risingwave"
service_account  = "risingwave"
s3_bucket_prefix = "risingwave-state-op-usxpress-qa"
```

Verify every key exists in `variables.tf` first — `aws_profile` and `region` are assumed.

## F4 — bucket name (my error in the original brief)

`main.tf` is `bucket = var.s3_bucket_prefix` — the variable holds the **full bucket
name**, not a prefix. The brief said `s3_bucket_prefix = "risingwave-state"`, which would
attempt a bucket literally named `risingwave-state`. Corrected in F3 above.

## F5 — no ServiceMonitor

Absent from the branch, so the platform Prometheus never scrapes RW and the dashboard
renders empty. Copy dev's rather than inventing port numbers:

```
git show origin/main:manifests/op-usxpress-dev/servicemonitor.yaml
```

Retarget selectors/namespace, add to `resources:`. Also fix the hardcoded datasource UID
`PBFA97CFB590B2093` in the dashboard JSON — that is RW's *own* Grafana's datasource; the
platform Grafana's UID differs, so every panel would show "Datasource not found."

## F6 — 1.15 MiB dev dashboard requires a manual UI import

`kustomization.yaml` documents importing it "via the Grafana API or UI" because it
exceeds the 1 MiB ConfigMap limit. That is a permanent manual step in a repo whose
standard is "no kubectl, everything through Flux," and prod inherits it.

Drop `risingwave-dev-dashboard.json` from QA — it's an RW-internal debug board; the
118 KB user dashboard is the one that matters. Revisit as a follow-up if genuinely needed.

---

## Open, not blocking merge

- **NodePorts 32114 / 31845 / 32567** — no collisions among existing services; confirm
  these three specific numbers are free. Platform standard is Istio ingress, so three
  NodePort services is a deviation that deserves a conscious decision.
- **Tim's inputs** — CR sizing is `replicas: 1` on meta/frontend/compactor (**no HA**) and
  compute at 2 CPU / 4Gi. Under "QA mirrors prod" this propagates to prod. Also needed:
  operator **chart** version pin (the RW image is pinned, the chart may not be) and S3
  retention.
- **Scope** — `rw-root-bootstrap-job.yaml` and `rw-service-accounts-bootstrap-job.yaml`
  create SQL users. That is app-layer work in Tim's namespace, outside the platform scope
  the brief drew.

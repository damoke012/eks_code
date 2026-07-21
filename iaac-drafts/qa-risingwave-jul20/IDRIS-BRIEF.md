# RisingWave → QA — brief for Idris (FINAL, verified 2026-07-21)

**Jira:** INFRA-1624 · **Sprint:** UI Sprint 2 · **Cluster:** `op-usxpress-qa` (on-prem Talos)
**Repo:** `variant-inc/iaac-risingwave-onprem`

Every value below is verified against the live cluster and AWS. Use them verbatim —
do not infer from dev; several dev settings are wrong for QA and are called out.

---

## Scope — PLATFORM layer only

Yours: RisingWave operator, RW CR, Postgres metastore, IRSA role, S3 bucket.
Not yours: SQL, materialised views, Kafka sources — Tim's app layer, shipped separately.

> This repo has a `migrations/` directory. If that's application SQL, flag it — platform
> and app shouldn't share a deployment path.

## Working standard

**PR → review → merge → Octopus/Flux deploys.** No `helm install`, no `kubectl apply`,
no local `terraform apply`. Prod will work identically.

---

## Confirmed QA values

| Item | Value |
|---|---|
| AWS account | `527101283767` |
| OIDC issuer | `d2t7d36wmf0hbm.cloudfront.net` |
| Namespace | `risingwave` (Tim's) + `risingwave-operator-system` |
| ServiceAccount | `risingwave` — do not rename |
| IAM role (created by your TF) | `op-usxpress-qa-risingwave` |
| S3 bucket (created by your TF) | `risingwave-state-op-usxpress-qa` |
| SM prefix | `op-usxpress-qa/risingwave/*` |
| Metastore StorageClass | **`ceph-block`** (dev uses `local-path` — do not copy) |
| Node placement | `nodeSelector: {pool: platform}` (labels verified present) |
| Frontend NodePort host | any worker, e.g. `10.10.82.138` — never a control plane |

⚠️ `risingwave-data-op-usxpress-qa` and `op-usxpress-qa-risingwave-2` belong to **RW-2**,
live in iaac-talos' Terraform state, and are trusted to
`system:serviceaccount:risingwave-2:risingwave`. Don't reuse or edit them.

---

## Deliverable 1 — Terraform (3-line fix, then the tfvars)

The IRSA block resolves OIDC via `data "aws_eks_cluster"`. QA is **Talos, not EKS**, so it
can't apply as-is. `variables.tf` already declares `oidc_issuer`, `namespace`,
`service_account` — they're just unused. Wire them in:

```diff
-data "aws_eks_cluster" "cluster" {
-  name = var.cluster_name
-}
-
 data "aws_iam_openid_connect_provider" "cluster" {
-  url = data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer
+  url = "https://${var.oidc_issuer}"
 }
```
```diff
-      values   = ["system:serviceaccount:risingwave:risingwave"]
+      values   = ["system:serviceaccount:${var.namespace}:${var.service_account}"]
```
```diff
 resource "aws_iam_role" "risingwave_irsa" {
-  name               = "risingwave-irsa"
+  name               = "${var.cluster_name}-risingwave"
```

`terraform/op-usxpress-qa.tfvars`:
```hcl
cluster_name     = "op-usxpress-qa"
region           = "us-east-2"
aws_profile      = "usx-qa"
oidc_issuer      = "d2t7d36wmf0hbm.cloudfront.net"
namespace        = "risingwave"
service_account  = "risingwave"
s3_bucket_prefix = "risingwave-state"
```

Clean create, **no `terraform import`** — nothing pre-exists on QA.
Applies via **Octopus** (`octo.yaml` → project `iaac-risingwave-onprem`, space `DevOps`,
scripts in `deploy/`), not GitHub Actions and not locally.

## Deliverable 2 — `manifests/op-usxpress-qa/`

Copy `manifests/op-usxpress-dev/` and retarget to the table above. Three deliberate
differences from dev:

**a. Metastore on replicated storage**
```yaml
# postgres-helmrelease.yaml
values:
  primary:
    persistence: { enabled: true, size: 20Gi, storageClass: ceph-block }
    nodeSelector: { pool: platform }
```

**b. Explicit node placement** — QA has `application`/`platform`/`system` pools; dev has
flat workers, so dev manifests carry no `nodeSelector` and RW would scatter. Every
component (operator, meta, frontend, compute, compactor, Postgres) gets
`nodeSelector: {pool: platform}`.

**c. DO NOT copy RW's own observability stack.** Dev ships
`prometheus-helmrelease.yaml`, `grafana-helmrelease.yaml`, `grafana.yaml`,
`grafana-dashboards-pvc.yaml` and dashboard JSON — a second Prometheus + Grafana inside
the RW namespace. QA's platform stack **already runs both**. For QA:
- **Omit** those four files.
- **Keep** `servicemonitor` so the platform Prometheus scrapes RW.
- Ship dashboards as ConfigMaps with the `grafana_dashboard` label for the platform
  Grafana's sidecar to pick up, instead of a dedicated Grafana + PVC.

Dev has the duplicate because RW predates the mature platform stack. QA is where we stop
carrying it forward.

## Deliverable 3 — `manifests/op-usxpress-qa/velero-schedule.yaml`

A PVC does **not** survive a cluster teardown. S3 holds streaming state; the metastore
only survives if backed up off-cluster.
```yaml
apiVersion: velero.io/v1
kind: Schedule
metadata: { name: risingwave-metastore, namespace: velero }
spec:
  schedule: "0 */6 * * *"
  template:
    includedNamespaces: [risingwave]
    includedResources: [persistentvolumeclaims, persistentvolumes, secrets]
    snapshotVolumes: true
    defaultVolumesToFsBackup: true
    ttl: 720h
```

## Deliverable 4 — close out PR #73

`iaac-talos-flux-platform` #73 (Argo CD) has been do-not-merge since 2026-07-10. Flux
already reconciles this repo into `risingwave`; a second controller on the same source
and namespace is split-brain, in Tim's namespace.

---

## Not yours — Doke's side
Deploy key (QA SM → ExternalSecret) and `clusters/op-usxpress-qa/risingwave.yaml`
(GitRepository + Kustomization, `dependsOn: [cert-manager, external-secrets]`).
**Don't touch `iaac-talos-flux-cluster`.** Your PR can merge first; it just won't
reconcile until that wiring lands.

## Tim's inputs — needed before the CR is final
Operator chart version pin · component sizing (QA mirrors prod, so it propagates) ·
S3 retention on the state store.

## Known QA caveat
QA's etcd backups are currently failing (INFRA-1623 — talosconfig in SM is a
placeholder). Doesn't block you; QA just isn't restorable at the control-plane layer yet.

## Follow-up (not now)
Dev's `op-usxpress-dev-risingwave` role was hand-provisioned and never imported — this
Terraform would have created `risingwave-irsa`, proving it's never been applied. Once QA
lands, backfill dev with `terraform import` so dev stops being un-codified.

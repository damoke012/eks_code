# iaac-talos-flux-platform — Flux CD Platform Resource Manifests

This repository holds the actual platform-layer Kubernetes manifests — `HelmRelease` objects,
Kustomize bases, `ClusterSecretStore` definitions, `CephCluster` specs, `CronJob`s, and
`VirtualService`s — that run on every on-prem Talos cluster operated by the Knight-Swift
Cloud Platform team. It is consumed by [`variant-inc/iaac-talos-flux-cluster`](https://github.com/variant-inc/iaac-talos-flux-cluster),
which contains the per-cluster sub-`Kustomization` objects that point Flux at the
`infrastructure/<component>/` directories defined here. Nothing in this repo is rendered or
applied directly by humans — Flux on each cluster is the only writer. The repo is the source
of truth for the platform layer: cluster bootstrap (`iaac-talos`) brings up nodes and seeds the
Flux GitRepository pointing here; this repo then drives every component that sits between the
kernel and the application workloads.

---

## Repo layout

```
iaac-talos-flux-platform/
├── README.md                                       (this file)
├── infrastructure/
│   ├── app-secrets/                                per-app ExternalSecret manifests (default CSS)
│   ├── arc-controller/                             actions-runner-controller (HelmRelease)
│   ├── arc-runner-rw-pipeline/                     ARC runner pool for RW SQL pipeline
│   ├── cert-manager/                               cert-manager controller HelmRelease
│   ├── cert-manager-issuers/                       LE wildcard ClusterIssuer + per-team issuers
│   ├── cilium-hygiene/                             node-reconciler CronJob (4 divergence modes)
│   ├── cilium-lb/                                  L2 IPPool + L2AnnouncementPolicy
│   ├── cross-cluster-app-secrets/                  per-app ExternalSecret (cross-cluster CSS)
│   ├── cross-cluster-eso/                          ESO bridge for cloud-EKS-source secrets
│   ├── ecr-credentials/                            CronJob renewing ECR pull credentials
│   ├── etcd-backup/                                hourly talosctl etcd snapshot → S3
│   ├── external-dns/                               Route 53 sync, IRSA-based
│   ├── external-secrets/                           external-secrets-operator HelmRelease
│   ├── external-secrets-config/                    default ClusterSecretStore → AWS SM
│   ├── grafana/                                    Grafana HelmRelease (observability Phase 4)
│   ├── istio/                                      istiod + ingress gateway + MeshConfig
│   ├── istio-csr/                                  cert-manager → istiod CSR bridge
│   ├── istio-ingress/                              Gateway + VirtualService primitives
│   ├── istio-namespace/                            istio-system namespace declaration + PSA
│   ├── istiod-health/                              periodic health-check CronJob + RBAC
│   ├── keda/                                       KEDA event-driven autoscaler
│   ├── kyverno/                                    kyverno policy engine HelmRelease
│   ├── kyverno-policies/                           ClusterPolicies (mutations + validations)
│   ├── octopus-worker/                             in-cluster Octopus tentacle
│   ├── pod-identity-webhook/                       mutating webhook injecting AWS_ROLE_ARN
│   ├── prometheus/                                 kube-prometheus-stack, ceph-block backed
│   ├── reloader/                                   stakater Reloader for ConfigMap/Secret churn
│   ├── risingwave-routes/                          rw-2 VS + Certificate (dashboard + SQL)
│   ├── rook-ceph-cluster/                          CephCluster CR + ServiceMonitor + SC
│   ├── rook-ceph-operator/                         rook-ceph operator HelmRelease + namespace
│   ├── rook-recovery-jobs/                         manual-apply destructive/diagnostic templates
│   ├── trust-manager/                              jetstack trust-manager HelmRelease
│   ├── trust-manager-bundle/                       Bundle CR (corp + internal CA distribution)
│   └── velero/                                     Kopia file-system backup → S3
└── .github/
    └── CODEOWNERS
```

Each `infrastructure/<component>/` directory is self-contained: it carries its own
`kustomization.yaml`, `namespace.yaml` (where applicable), `helmrelease.yaml` or hand-rolled
manifests, and any `ExternalSecret` / `ServiceAccount` glue the component needs. The contract
with `iaac-talos-flux-cluster` is simply the path — that repo's per-cluster Kustomization
points at `infrastructure/<name>` and Flux reconciles whatever lives there.

---

## Branch convention

This repo is multi-cluster. Each cluster consumes a dedicated branch; cross-cluster promotion
is a merge or fast-forward between branches, never a directory rename.

| Branch       | Cluster                              | Status                       |
|--------------|--------------------------------------|------------------------------|
| `op-dev`     | `op-usxpress-dev` (on-prem Talos)    | live; **default branch**     |
| `qa-dev`     | future on-prem QA cluster            | placeholder                  |
| `prod`       | legacy default (cloud bring-up)      | preserved for history        |
| `op-prod`    | future on-prem prod cluster          | not yet cut                  |

**The default branch was flipped from `prod` to `op-dev` on 2026-06-23** as part of the
marathon close-out. Rationale: `prod` had been dormant since the dpl2 → op-usxpress-dev cutover,
PRs were being mis-targeted at `prod` by default and silently sitting unmerged, and the only
live consumer of the repo today is the `op-usxpress-dev` cluster reading `op-dev`. The old
`prod` branch is preserved (do not delete) so future on-prem prod bring-up can fast-forward off
its history if needed; the on-prem prod cluster itself will likely be cut as `op-prod`.

Per-cluster bring-up flow:

1. Branch off `op-dev` at the commit currently green on dev.
2. Search-replace cluster identifiers in `HelmRelease` values (S3 bucket names, IRSA role
   ARNs, AWS region, Route 53 hosted zone, Ceph cluster name).
3. Push the new branch and add a `GitRepository` + `Kustomization` pair in
   `iaac-talos-flux-cluster` pointing at it.
4. The new cluster's Flux pulls only its own branch — no cross-branch reconciliation.

---

## How Flux reads this repo

`iaac-talos-flux-cluster` carries one top-level `flux-system` `Kustomization` per cluster
(e.g. `clusters/op-usxpress-dev/`) which in turn declares one sub-`Kustomization` per
component listed below. Each sub-`Kustomization` looks like:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: velero
  namespace: flux-system
spec:
  interval: 10m
  path: ./infrastructure/velero
  prune: true
  sourceRef:
    kind: GitRepository
    name: iaac-talos-flux-platform
  wait: true
  timeout: 5m
  dependsOn:
    - name: external-secrets-config
```

The `GitRepository` named `iaac-talos-flux-platform` (defined once per cluster in
`iaac-talos-flux-cluster`) carries `ref.branch: op-dev` for `op-usxpress-dev`. Flux pulls,
builds the Kustomize overlay at `path`, and applies it under server-side apply with the
inventory pinned to the `Kustomization`'s name/namespace.

**Critical**: see the Flux `kstatus` terminal-failure gotcha at the bottom of this README.
A `Kustomization` whose `status.conditions[Reconciled].reason == "BuildFailed"` is **not
retried** — it is settled. A 32-day cascade was caused by this misreading; verify with
`flux get kustomizations -A | grep -v True` rather than waiting.

---

## Platform components

### Component inventory

The repo carries 34 platform components. The table below is the at-a-glance index; per-component
detail follows in the sections after, grouped by functional domain.

| Component                  | Purpose                                                                  | Chart vs Kustomize | Key dependencies                          | jun23 marathon touch |
|----------------------------|--------------------------------------------------------------------------|--------------------|-------------------------------------------|----------------------|
| rook-ceph-operator         | Rook operator that runs the CephCluster CR                               | Chart (rook)       | namespace `rook-ceph`                     | N                    |
| rook-ceph-cluster          | CephCluster CR + ceph-block StorageClass + ServiceMonitor                | Kustomize          | rook-ceph-operator                        | Y (PR #54, #57)      |
| rook-recovery-jobs         | Manual-apply destructive/diagnostic Job templates                        | Kustomize          | rook-ceph-cluster                         | N                    |
| cilium-lb                  | L2 LoadBalancer IPPool + L2AnnouncementPolicy                            | Kustomize          | cilium CNI (Talos-bundled)                | N                    |
| cilium-hygiene             | CronJob auto-remediating 4 Cilium divergence modes                       | Kustomize          | cilium CNI                                | N                    |
| external-secrets           | external-secrets-operator HelmRelease                                    | Chart (ESO)        | namespace `external-secrets`              | N                    |
| external-secrets-config    | Default ClusterSecretStore → AWS SM via IRSA                             | Kustomize          | external-secrets, IRSA role               | N                    |
| cross-cluster-eso          | Second CSS pointing at a cloud-EKS API server                            | Kustomize          | external-secrets, Octopus seed            | N                    |
| cross-cluster-app-secrets  | Per-app ExternalSecret manifests via cross-cluster CSS                   | Kustomize          | cross-cluster-eso                         | N                    |
| app-secrets                | Per-app ExternalSecret manifests via default CSS                         | Kustomize          | external-secrets-config                   | N                    |
| ecr-credentials            | CronJob renewing ECR pull credentials                                    | Kustomize          | IRSA role for ECR GetAuthorizationToken   | N                    |
| pod-identity-webhook       | Mutating webhook injecting AWS_ROLE_ARN into IRSA pods                   | Kustomize          | cert-manager (TLS for webhook)            | N                    |
| velero                     | Kopia file-system PVC + manifest backup → S3                             | Chart (bitnamilegacy)| external-secrets-config, IRSA role      | Y (PR #55/#59/#60)   |
| etcd-backup                | Hourly `talosctl etcd snapshot` → S3 (multi-container)                   | Kustomize          | external-secrets-config, IRSA role        | Y (PR #58/#61/#62)   |
| prometheus                 | kube-prometheus-stack, ceph-block backed                                 | Chart (kps)        | rook-ceph-cluster                         | Y (PR #56)           |
| grafana                    | Grafana HelmRelease + ExternalSecret + values CM                         | Chart              | external-secrets-config, prometheus       | N                    |
| reloader                   | Stakater Reloader — rolls Deployments on CM/Secret change                | Chart              | namespace `reloader`                      | N                    |
| istiod-health              | Periodic health-check CronJob detecting istiod cert drift                | Kustomize          | istio, RBAC                               | N                    |
| cert-manager               | cert-manager controller HelmRelease                                      | Chart (jetstack)   | namespace `cert-manager`                  | N                    |
| cert-manager-issuers       | LE wildcard ClusterIssuer + per-team issuers                             | Kustomize          | cert-manager, IRSA role for DNS-01        | N                    |
| istio                      | istiod + ingress gateway DaemonSet + MeshConfig                          | Chart (istio)      | istio-namespace, istio-csr                | N                    |
| istio-csr                  | cert-manager → istiod CSR bridge                                         | Chart              | cert-manager, istio-namespace             | N                    |
| istio-ingress              | Gateway + VirtualService primitives (corp VPN CNP, TCP passthrough)      | Kustomize          | istio                                     | N                    |
| istio-namespace            | `istio-system` namespace + PSA labels                                    | Kustomize          | —                                         | N                    |
| external-dns               | Route 53 sync (Service + Ingress + VirtualService sources)               | Chart (external-dns v0.20.0) | external-secrets-config, IRSA role | N                |
| trust-manager              | jetstack trust-manager HelmRelease                                       | Chart (jetstack)   | cert-manager                              | N                    |
| trust-manager-bundle       | Bundle CR distributing corp + internal CA bundles                        | Kustomize          | trust-manager                             | N                    |
| risingwave-routes          | rw-2 dashboard/overview VS + SQL passthrough VS + Certificate            | Kustomize          | istio-ingress, cert-manager-issuers       | N                    |
| arc-controller             | actions-runner-controller HelmRelease                                    | Chart (ARC)        | cert-manager                              | N                    |
| arc-runner-rw-pipeline     | Self-hosted ARC runner pool for RW SQL pipeline                          | Kustomize          | arc-controller, external-secrets-config   | N                    |
| octopus-worker             | In-cluster Octopus tentacle for TF apply / runbook execution             | Chart              | external-secrets-config                   | N                    |
| keda                       | KEDA event-driven autoscaler                                             | Chart (KEDA)       | namespace `keda`                          | N                    |
| kyverno                    | Kyverno policy engine HelmRelease                                        | Chart (kyverno)    | namespace `kyverno`                       | N                    |
| kyverno-policies           | ClusterPolicies (auto-grafana-folder-label, policy-mongo-atlas, etc.)    | Kustomize          | kyverno                                   | N                    |

The per-component sub-sections that follow are grouped:

1. Core platform — rook-ceph-operator, rook-ceph-cluster, rook-recovery-jobs, cilium-lb, cilium-hygiene
2. Secrets — external-secrets, external-secrets-config, cross-cluster-eso, cross-cluster-app-secrets, app-secrets, ecr-credentials, pod-identity-webhook
3. Backup — velero, etcd-backup
4. Observability — prometheus, grafana, reloader, istiod-health
5. Networking + TLS — cert-manager, cert-manager-issuers, istio, istio-csr, istio-ingress, istio-namespace, external-dns, trust-manager, trust-manager-bundle, risingwave-routes
6. CI/CD + autoscaling — arc-controller, arc-runner-rw-pipeline, octopus-worker, keda
7. Policy — kyverno, kyverno-policies

---

## Core platform

### rook-ceph-operator (`infrastructure/rook-ceph-operator/`)

**Purpose.** The Rook operator pod and its CRDs. Owns reconciliation of the `CephCluster` CR
declared in `rook-ceph-cluster` and every downstream Ceph daemon (mons, mgr, OSDs, MDS where
relevant). Carries the `rook-ceph` namespace itself and the operator's RBAC, webhook
configuration, and Helm-managed CRDs.

**Source.** `rook-ceph` chart from `https://charts.rook.io/release`. HelmRelease at
`infrastructure/rook-ceph-operator/helmrelease.yaml`; HelmRepository declared in the same
directory (or at the cluster-flux-system level depending on the bring-up).

**Key values / manifests.**

- `infrastructure/rook-ceph-operator/namespace.yaml` — `rook-ceph` namespace with privileged
  PSA labels (`pod-security.kubernetes.io/enforce: privileged`). Required — the operator runs
  privileged Pods (CSI provisioner, OSD prepare jobs) that PSA-restricted would block.
- `infrastructure/rook-ceph-operator/helmrelease.yaml` — chart `rook-ceph` (operator-only,
  no CephCluster). CRDs install via the chart.
- `infrastructure/rook-ceph-operator/kustomization.yaml` — wires namespace + HelmRepository +
  HelmRelease together.

**IRSA / dependencies.** None — Rook runs cluster-local; the operator has no AWS calls.
Depends on a working CNI (Cilium) for pod networking and on Talos-side device discovery
(the Talos machine config exposes the disks Rook will claim).

**Verified state.**

- Operator Deployment Ready in `rook-ceph`.
- CRDs (`CephCluster`, `CephBlockPool`, `CephFilesystem`, etc.) registered.
- Webhook serving cert issued by cert-manager when the chart is configured to use one;
  default operator webhook otherwise.

**Gotchas.**

- The `rook-ceph` namespace **must** be created before the CRDs install or the operator's
  initial cluster-role binding will reference a missing namespace.
- The Rook chart's `enableDiscoveryDaemon` option is OFF on this cluster — disks are statically
  declared in the `CephCluster` spec (`rook-ceph-cluster`) rather than discovered. Avoids the
  discovery DaemonSet hot-looping on the Talos system disk's read-only partitions.

---

### rook-ceph-cluster (`infrastructure/rook-ceph-cluster/`)

**Purpose.** The actual `CephCluster` CR plus the `CephBlockPool` and `StorageClass` that
expose RBD as `ceph-block`. Also carries the `ServiceMonitor` that lets Prometheus scrape Ceph
mgr metrics. Conceptually the "second half" of Rook — the operator (above) runs the
controller, this directory declares the cluster the operator manages.

**Source.** Hand-rolled Kustomize. No chart — the CephCluster CR is too cluster-specific
(disk paths, mon counts, mgr resources) to share a chart sensibly across clusters.

**Key values / manifests.**

```yaml
# infrastructure/rook-ceph-cluster/cephcluster.yaml (excerpt)
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: rook-ceph
  namespace: rook-ceph
spec:
  resources:
    mgr:
      limits:
        memory: 2Gi              # was 512Mi default — OOMKilled 135× in 16h on dev
      requests:
        memory: 1Gi
    osd:
      limits:
        memory: 4Gi
      requests:
        memory: 1Gi
```

- `infrastructure/rook-ceph-cluster/cephcluster.yaml` — `CephCluster` CR with static device
  paths per node, 3-mon spread, mgr 2Gi (post-PR #54), OSD memory 4Gi.
- `infrastructure/rook-ceph-cluster/cephblockpool.yaml` — `replicated` pool with size 3.
- `infrastructure/rook-ceph-cluster/storageclass.yaml` — `ceph-block` `StorageClass`,
  `volumeBindingMode: Immediate`, `reclaimPolicy: Delete`.
- `infrastructure/rook-ceph-cluster/toolbox.yaml` — always-on toolbox `Deployment` (PR #57).
- `infrastructure/rook-ceph-cluster/servicemonitor.yaml` — Prometheus scrape against ceph-mgr
  metrics.

**IRSA / dependencies.**

- Cluster-local; no AWS.
- Depends on `rook-ceph-operator` (its `Kustomization` carries
  `dependsOn: [name: rook-ceph-operator]`).
- Depends on disks being present on the workers — Talos machine config carries the device
  declarations.

**Verified state.**

- `ceph-block` `StorageClass` registered and set as default.
- ~350 GiB usable; 4 OSDs healthy across workers.
- mgr no longer OOM-killing after the 2 GiB bump (was 135 OOMs in 16h pre-PR #54).
- Toolbox `Deployment` Ready in `rook-ceph` — first prod customer of the always-on
  toolbox pattern.
- Prometheus scraping `ceph_*` metrics via the `ServiceMonitor`.

**Gotchas.**

- The bluestore label on each OSD device is the **source of truth** for OSD identity — never
  re-label a device that already carries a bluestore label, you will lose the OSD's data.
- Default `mgr.memory: 512Mi` is too small for any cluster doing real work. Bump to 2Gi.
- `CephCluster.spec.network.provider: host` is **off** on this cluster — Cilium CNI handles
  pod networking and Rook's default `multus` is not configured. Don't flip to `host` casually,
  it changes how OSDs advertise to clients.

---

### rook-recovery-jobs (`infrastructure/rook-recovery-jobs/`)

**Purpose.** Manual-apply templates for Ceph recovery operations. Intentionally **not part of
the standard reconcile** — Flux does not own these; an operator applies them with `kubectl`
when the situation calls for it.

**Source.** Hand-rolled Kustomize. The directory carries a `kustomization.yaml` so the
templates can be applied with `kubectl apply -k` against a vetted overlay, but no upstream
`Kustomization` resource references them. They are documented inert manifests.

**Key values / manifests.**

- `osd-wipe.yaml` — privileged Job that runs `dd if=/dev/zero` against a named device. Use
  ONLY when an OSD is being decommissioned and a fresh OSD will take its place. Destroys data
  by design.
- `bluestore-inspect.yaml` — read-only diagnostic Job that runs `ceph-bluestore-tool` against
  a mounted device. Safe to apply against any device; reads the bluestore label and superblock
  and dumps to stdout.
- `toolbox.yaml` — bring up a one-shot toolbox Pod when the always-on toolbox is unavailable
  (e.g. during a Ceph upgrade window).

**IRSA / dependencies.** None — cluster-local privileged operations.

**Verified state.** Templates exist; `bluestore-inspect.yaml` exercised against
`op-usxpress-dev` OSDs during the bluestore label = SOT investigation.

**Gotchas.** `osd-wipe.yaml` is destructive. Confirm the device name **on the right node**
(`lsblk` from a `nsenter` debug pod) before applying. Misnaming will wipe a healthy OSD or,
worse, a Talos system disk.

---

### cilium-lb (`infrastructure/cilium-lb/`)

Purpose: L2 LoadBalancer support — `CiliumLoadBalancerIPPool` + `CiliumL2AnnouncementPolicy`
backing `Service type=LoadBalancer` for on-prem ingress. No external L4 LB on dev — Cilium
ARP-announces the configured IP pool on the workers' L2 segment.
Source: Kustomize; CRs defined in `pool.yaml` and `l2policy.yaml`.
See: `onprem_external_access_l2_vs_nodeport`, `onprem_hostnetwork_ingress_proof` (memory).

---

### cilium-hygiene (`infrastructure/cilium-hygiene/`)

Purpose: CronJob that auto-remediates Cilium node drift across 4 known divergence modes
(missing CiliumNode object, stale identity, leaked endpoint, orphan IP). Runs every 15 min;
takes corrective `kubectl` action when a heuristic matches.
Source: Kustomize. CronJob + RBAC + namespace `cilium-hygiene`.
See: `cilium_node_reconciler_live_jun18` (memory).

---

## Secrets

### external-secrets (`infrastructure/external-secrets/`)

Purpose: The `external-secrets-operator` HelmRelease itself — controller + webhook + cert that
runs the ESO CRDs (`ExternalSecret`, `SecretStore`, `ClusterSecretStore`).
Source: Chart `external-secrets` from `https://charts.external-secrets.io`. HelmRelease +
namespace `external-secrets`.
See: `external-secrets-config` for the CSS objects this operator reconciles against AWS SM.

---

### external-secrets-config (`infrastructure/external-secrets-config/`)

**Purpose.** The default `ClusterSecretStore` (CSS) — points at AWS Secrets Manager in account
`700736442855` (USX-Dev) via IRSA. This is what 95% of `ExternalSecret` objects in the cluster
target. Every secret the on-prem cluster owns lives in SM under `op-usxpress-dev/<name>`.

**Source.** Hand-rolled Kustomize. CSS plus the SA that IRSA-binds to it.

**Key values / manifests.**

```yaml
# infrastructure/external-secrets-config/clustersecretstore.yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-sm-usx-dev
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-2
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
```

**IRSA / dependencies.**

- SA `external-secrets/external-secrets` bound to `op-usxpress-dev-external-secrets` IAM role.
- `iaac-talos` `modules/irsa/external-secrets` provisions the role with
  `secretsmanager:GetSecretValue` / `DescribeSecret` against `op-usxpress-dev/*`.
- Hard dependency: `external-secrets` Kustomization must be Ready first.

**Verified state.** Default CSS resolving `op-usxpress-dev/*` secrets across `velero`,
`etcd-backup`, `cert-manager`, `external-dns`, and every app namespace.

**Gotchas.**

- CSS `Ready` is necessary but not sufficient — an individual `ExternalSecret` can still fail
  to resolve if the SM secret it references does not exist. Check
  `kubectl get externalsecret -A` not just the CSS.
- Role-name reuse across clusters is **prohibited** — `op-usxpress-dev-external-secrets`
  belongs to dev only. QA / prod brings their own.

---

### cross-cluster-eso (`infrastructure/cross-cluster-eso/`)

**Purpose.** A second CSS pointing at a cloud EKS cluster's API server, used when the secret's
source of truth is a cloud-side `Secret` provisioned by cloud Terraform (e.g. ArgoCD-managed
app config). Only secrets the cloud TF writes **directly** should bridge through this path;
anything the cloud TF ultimately reads from AWS SM should be re-pointed at the default CSS
instead.

**Source.** Hand-rolled Kustomize. CSS plus a Secret holding the kubeconfig-style token that
authenticates to the cloud EKS API.

**Key values / manifests.**

```yaml
# infrastructure/cross-cluster-eso/clustersecretstore.yaml (excerpt)
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: cross-cluster-eks-dev
spec:
  provider:
    kubernetes:
      remoteNamespace: <ns-on-cloud-EKS>
      server:
        url: https://<cloud-EKS-API>
        caBundle: <base64-CA>
      auth:
        token:
          bearerToken:
            name: cross-cluster-token
            namespace: external-secrets
            key: token
```

The cross-cluster CSS is **split into its own Flux `Kustomization` with `wait: false`**
in the consumer repo (`iaac-talos-flux-cluster`). Rationale: the bearer token is seeded by an
Octopus runbook AFTER Flux comes up. `wait: true` would block forever during bootstrap
(chicken-and-egg).

**IRSA / dependencies.** **Not IRSA.** Uses a kubeconfig-style bearer token seeded into a
Secret by the Octopus bootstrap runbook. The Octopus project carries the cloud-side SA token
and a step that writes it into `external-secrets/cross-cluster-token`.

**Verified state.** CSS healthy after Octopus seeds the token. Currently bridges
`geoenrichment-sync-handler-m-u` mongo-atlas creds.

**Gotchas.**

- Single-point-of-failure for any app that depends on it. POC-only pattern; production-grade
  workloads should migrate to a default-CSS-friendly source. Tracked under
  `onprem_prod_readiness_cross_cluster_eso_spof` (memory).
- Bootstrap order matters — the cross-cluster Kustomization carries `wait: false` precisely so
  that a missing cross-cluster token at first reconcile does not stall the rest of the
  platform.

---

### cross-cluster-app-secrets (`infrastructure/cross-cluster-app-secrets/`)

Purpose: Per-app `ExternalSecret` manifests that point at the cross-cluster CSS rather than
the default CSS. Currently carries `geoenrichment-sync-handler-m-u` (mongo-atlas creds
originating from cloud-EKS).
Source: Kustomize. One `ExternalSecret` per consumer app.
See: `cloud_to_onprem_workload_patterns_jun02`, `onprem_mongo_atlas_v2_architectural` (memory).

---

### app-secrets (`infrastructure/app-secrets/`)

Purpose: Per-app `ExternalSecret` manifests that point at the default CSS. Currently carries
`brands-api` and `geoenrichment-sync-handler`. Pattern: one ExternalSecret per consumer app
pointing at AWS SM `op-usxpress-dev/<app>/<key>`.
Source: Kustomize.

---

### ecr-credentials (`infrastructure/ecr-credentials/`)

Purpose: CronJob + RBAC that periodically calls `ecr:GetAuthorizationToken` in the
`064859874041` (DevOps / ECR) account and writes the resulting docker-registry pull secret
into the namespaces that need it. Without this, in-cluster image pulls from `variant-inc`
ECR would 401 every 12h when the token rotates.
Source: Kustomize. CronJob + ServiceAccount + IRSA-annotated SA.

---

### pod-identity-webhook (`infrastructure/pod-identity-webhook/`)

**Purpose.** The mutating admission webhook that injects `AWS_ROLE_ARN`,
`AWS_WEB_IDENTITY_TOKEN_FILE`, and the projected SA token volume into Pods whose
ServiceAccount carries the `eks.amazonaws.com/role-arn` annotation. **Without this, IRSA
ServiceAccounts do not work on a self-managed cluster** — EKS-managed clusters get the
equivalent webhook automatically; Talos does not.

**Source.** Hand-rolled Kustomize. Deployment + Service + MutatingWebhookConfiguration +
Certificate (issued by cert-manager) + namespace `pod-identity-webhook`.

**Key values / manifests.**

- `infrastructure/pod-identity-webhook/namespace.yaml` — `pod-identity-webhook` namespace.
- `infrastructure/pod-identity-webhook/deployment.yaml` — webhook server Pod with TLS cert
  mounted from a cert-manager-issued Secret.
- `infrastructure/pod-identity-webhook/certificate.yaml` — `cert-manager.io/v1/Certificate`
  for the webhook's serving TLS. Issuer is the internal CA (selfsigned-root chain).
- `infrastructure/pod-identity-webhook/mutatingwebhookconfiguration.yaml` — webhook spec
  matching Pods and rewriting the spec to add the projected token volume + env.

**IRSA / dependencies.**

- Depends on `cert-manager` and on the internal-CA `Issuer` (carried by
  `cert-manager-issuers`).
- Does not itself use IRSA — it is what _makes_ IRSA work for everything else.

**Verified state.**

- Webhook Deployment Ready in `pod-identity-webhook`.
- Every IRSA-annotated SA produces Pods with `AWS_ROLE_ARN` env and the projected token
  volume mounted at `/var/run/secrets/eks.amazonaws.com/serviceaccount/token`.
- Spot-checked against `velero/velero`, `external-dns/external-dns`,
  `external-secrets/external-secrets`, `etcd-backup/etcd-backup`.

**Gotchas.**

- The webhook is a `Mutating` admission step — it fires **at Pod create**, not on
  ServiceAccount update. If an IRSA annotation is added to an SA after Pods already exist,
  those Pods do **not** retroactively get the env / volume. A `pod delete` to trigger
  re-creation is required. The marathon caught this on external-dns: the SA was flipped to
  IRSA after the Deployment was already running; a `kubectl delete pod -l app=external-dns`
  fixed it. Follow-up Kyverno policy to detect this state tracked under INFRA-1555 (deferred).
- The webhook serving cert must be valid before the webhook can serve, but cert-manager won't
  issue the cert until the cert-manager `Issuer` is Ready, which depends on... cert-manager
  being up. Bootstrap order: cert-manager → cert-manager-issuers → pod-identity-webhook.
- The MutatingWebhookConfiguration's `failurePolicy` is `Ignore` on this cluster — a
  webhook outage degrades IRSA injection but does not block Pod creation. Trade-off chosen
  to avoid a webhook-down event from cascading into a cluster-wide Pod-creation outage.

---

## Backup

### velero (`infrastructure/velero/`)

**Purpose.** Cluster-wide PVC + manifest backup, Kopia file-system snapshot mode, S3-backed,
IRSA auth. Backs up everything in the cluster minus `kube-system` and `flux-system` (Flux is
the source of truth for those — restoring stale objects from a snapshot would fight the
reconciler).

**Source.** Chart `bitnamilegacy/velero` (was `bitnami/velero` until Bitnami removed
versioned tags from `bitnami/*` on 2026-06-19; see common gotchas).

**Key values / manifests.**

```yaml
# infrastructure/velero/helmrelease.yaml (excerpt)
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: velero
  namespace: velero
spec:
  interval: 10m
  chart:
    spec:
      chart: velero
      version: 9.x.x
      sourceRef:
        kind: HelmRepository
        name: bitnamilegacy
        namespace: flux-system
  values:
    image:
      registry: docker.io
      repository: bitnamilegacy/velero
    kubectl:
      image:
        registry: docker.io
        repository: bitnamilegacy/kubectl
        tag: "1.32"        # bitnami/kubectl:1.32 404s — versioned tag pulled by Bitnami
    serviceAccount:
      server:
        create: true
        name: velero
        annotations:
          eks.amazonaws.com/role-arn: arn:aws:iam::700736442855:role/op-usxpress-dev-velero
    configuration:
      backupStorageLocation:
        - name: default
          provider: aws
          bucket: velero-op-usxpress-dev
          config:
            region: us-east-2
      volumeSnapshotLocation:
        - name: default
          provider: aws
          config:
            region: us-east-2
      defaultVolumesToFsBackup: true   # Kopia file-system mode, not CSI snapshots
      uploaderType: kopia
      extraEnvVars:
        - name: AWS_REGION
          value: us-east-2
    nodeAgent:
      enabled: true
      # DO NOT set nodeAgent.extraEnvVars — chart renders configuration.extraEnvVars
      # onto the node-agent DS as well; duplicate AWS_REGION = SSA duplicate-key error
      # → silent helm rollback. See "Velero gotcha catalog" below.
    schedules:
      daily-full:
        schedule: "0 2 * * *"           # 02:00 UTC daily
        template:
          ttl: 336h0m0s                 # 14 days
          includedNamespaces:
            - "*"
          excludedNamespaces:
            - kube-system
            - flux-system
          defaultVolumesToFsBackup: true
```

**IRSA / dependencies.** ServiceAccount `velero/velero` annotated with the IAM role created by
the matching module in [`iaac-talos`](https://github.com/variant-inc/iaac-talos) PR #44
(`modules/irsa/velero`). The role has `s3:*Object` + `s3:ListBucket` against
`velero-op-usxpress-dev` plus the EBS / EFS volume snapshot actions Velero registers even when
unused.

**Verified state.**

- Daily-full schedule firing at 02:00 UTC; backup objects landing in
  `s3://velero-op-usxpress-dev/backups/`.
- Restore tested end-to-end: `test-restore-jun24` restored a 20 GiB `ceph-block` PVC; 3
  application pods came back Running and consumed the restored data with no drift.
- Node-agent DS Running on all 7 workers; no pods on control plane (intentional — CPs are
  Talos-managed and carry no stateful workloads).

**Gotchas.** See the dedicated [Velero gotcha catalog](#velero-gotcha-catalog) section.
Short list: do not double-set `extraEnvVars`; Kopia needs `AWS_REGION` as an env var (BSL
`config.region` alone is insufficient); the chart pins `bitnami/kubectl:<minor>` which now
404s — override to `bitnamilegacy/kubectl:1.32`.

---

### etcd-backup (`infrastructure/etcd-backup/`)

**Purpose.** Hourly `talosctl etcd snapshot` of the Talos control-plane etcd, uploaded to S3.
This is a belt-and-braces backup for the cluster itself — Velero protects workloads, this
protects the cluster's identity. Recovery from this snapshot is what saved us during the
[2026-06-17 CP OOM cascade](https://github.com/variant-inc/iaac-talos/blob/feature/op-usxpress-dev/deploy/docs/troubleshooting/cp-oom-cascade.md).

**Source.** Hand-rolled Kustomize — no chart. A chart for this would be over-engineering
for a single resource.

**Key values / manifests.**

```yaml
# infrastructure/etcd-backup/cronjob.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: etcd-snapshot-to-s3
  namespace: etcd-backup
spec:
  schedule: "17 * * * *"               # hourly at :17, offset from kube cron jitter
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          restartPolicy: Never
          serviceAccountName: etcd-backup
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            runAsGroup: 1000
            fsGroup: 1000
            seccompProfile:
              type: RuntimeDefault
          volumes:
            - name: talosconfig
              secret:
                secretName: talosconfig
                defaultMode: 0400
            - name: work
              emptyDir:
                medium: ""             # NOT Memory — tmpfs accounting OOM-killed initContainer
                sizeLimit: 2Gi
          initContainers:
            - name: snapshot
              image: ghcr.io/siderolabs/talosctl:v1.10.4    # distroless — no /bin/sh
              command:
                - /talosctl
              args:
                - --talosconfig=/etc/talos/config
                - --endpoints=10.10.82.50
                - --nodes=10.10.82.50
                - etcd
                - snapshot
                - /work/snapshot.db
              resources:
                requests: { cpu: 100m, memory: 512Mi }
                limits:   { cpu: 500m, memory: 1Gi }
              volumeMounts:
                - { name: talosconfig, mountPath: /etc/talos, readOnly: true }
                - { name: work,        mountPath: /work }
          containers:
            - name: upload
              image: amazon/aws-cli:2.17.0
              command: ["/bin/bash","-c"]
              args:
                - |
                  set -euo pipefail
                  TS=$(date -u +%Y-%m-%dT%H-%M-%SZ)
                  aws s3 cp /work/snapshot.db \
                    "s3://etcd-snapshots-op-usxpress-dev/op-usxpress-dev/${TS}/snapshot.db" \
                    --region us-east-2
              env:
                - { name: AWS_REGION, value: us-east-2 }
              resources:
                requests: { cpu: 50m,  memory: 128Mi }
                limits:   { cpu: 200m, memory: 256Mi }
              volumeMounts:
                - { name: work, mountPath: /work }
```

**Talosconfig source.** Pulled via `ExternalSecret` from AWS Secrets Manager secret
`op-usxpress-dev/talosconfig` (imported into Terraform state by ARN — see the AWS SM ARN-vs-name
gotcha in the iaac-talos README). The CSS target is the default `ClusterSecretStore` defined
under `infrastructure/external-secrets-config/`.

**IRSA / dependencies.** ServiceAccount `etcd-backup/etcd-backup` assumes the role provisioned
by `iaac-talos` `modules/irsa/etcd-backup`. The role's policy is narrow:
`s3:PutObject` against `etcd-snapshots-op-usxpress-dev/op-usxpress-dev/*`.

**Verified state.**

- Most recent snapshot: **287.2 MiB** at
  `s3://etcd-snapshots-op-usxpress-dev/op-usxpress-dev/<TS>/snapshot.db`.
- etcd content at snapshot time: revision 59349168, 10994 keys.
- Hourly cadence verified across a 24-hour window — no missed runs, no OOMs after the
  workdir-off-tmpfs change.

**Gotchas.** See [etcd-backup multi-container pattern](#etcd-backup-multi-container-pattern)
below for the talosctl-distroless reasoning, the tmpfs-accounting failure mode, and the
1 GiB memory bump rationale.

---

## Observability

### prometheus (`infrastructure/prometheus/`)

**Purpose.** kube-prometheus-stack (Prom + Alertmanager + node-exporter + kube-state-metrics)
scraping the on-prem cluster. Mirror of the cloud `iaac-monitoring` topology, scoped down to
what an on-prem cluster needs (no remote-write yet — that lands in observability Phase 6).

**Source.** Chart `prometheus-community/kube-prometheus-stack`.

**Key values / manifests.**

```yaml
# infrastructure/prometheus/helmrelease.yaml (excerpt)
spec:
  values:
    prometheus:
      prometheusSpec:
        retention: 30d
        retentionSize: 18GiB
        storageSpec:
          volumeClaimTemplate:
            spec:
              storageClassName: ceph-block
              accessModes: ["ReadWriteOnce"]
              resources:
                requests:
                  storage: 20Gi
```

Prior to PR #56 this was an `emptyDir` — every pod restart (image pull, node maintenance, OOM)
dropped the entire 4.9 GiB TSDB on the floor. Moving to `ceph-block` is the **first production
workload on `ceph-block`** — a deliberate first customer that exercises Ceph under sustained
small-block write load before any RW-2 stateful workload follows.

**IRSA / dependencies.** None — Prometheus runs cluster-local; no AWS calls.
Hard dependency on `rook-ceph-cluster` (the `ceph-block` SC must exist before the PVC binds).

**Verified state.** PVC bound to a `ceph-block` RBD volume, Prom Running, TSDB persisted
across a pod restart, RW-2 also moved its Prometheus-server PVC to `ceph-block` as the second
customer on the SC.

**Gotchas.** `retentionSize` must be slightly less than the PVC `storage` request so that
WAL + head + index headroom does not bump into the PVC limit (`retentionSize` is steady-state
on-disk, not peak).

---

### grafana (`infrastructure/grafana/`)

**Purpose.** Grafana UI for the on-prem `prometheus` stack. Observability Phase 4 of the
9-phase mirror plan (INFRA-1520). Provides dashboards for Ceph, Cilium, istio, RW-2, and
the core kube-state set.

**Source.** Chart `grafana/grafana`. HelmRelease + ExternalSecret + helm-values-configmap.

**Key values / manifests.**

- `infrastructure/grafana/namespace.yaml` — `grafana` namespace, PSA-restricted.
- `infrastructure/grafana/helmrelease.yaml` — chart `grafana`, datasource provisioning
  pointing at `prometheus.prometheus.svc:9090`, persistence on `ceph-block`.
- `infrastructure/grafana/externalsecret.yaml` — admin password sourced from AWS SM
  `op-usxpress-dev/grafana/admin`.
- `infrastructure/grafana/configmap.yaml` — helm values overlay carrying dashboard JSON
  references and SSO config (azure-AD OAuth via the USX tenant).

**IRSA / dependencies.**

- `external-secrets-config` (admin password ExternalSecret).
- `prometheus` (datasource target).
- `rook-ceph-cluster` (PVC for dashboard storage).
- `cert-manager-issuers` (TLS for the public hostname).
- `external-dns` (publishes the public hostname).

**Verified state.**

- Grafana pod Running with the Prom datasource green.
- Admin password loaded from SM via ExternalSecret.
- Persistence PVC bound on `ceph-block`.
- INFRA-1520 closed.

**Gotchas.**

- The Grafana chart's `admin.existingSecret` field expects keys `admin-user` and
  `admin-password` — match the ExternalSecret's `data[].secretKey` exactly or the pod
  CrashLoopBackOffs without a useful error.
- Dashboard folder labels are auto-applied by the `auto-grafana-folder-label` Kyverno policy
  (`kyverno-policies`). If a new dashboard ConfigMap appears unlabeled, that policy will
  add the label — do not hand-set it in this repo.

---

### reloader (`infrastructure/reloader/`)

**Purpose.** Stakater Reloader — watches ConfigMaps and Secrets, and rolls Deployments that
annotate themselves with `reloader.stakater.com/auto: "true"` or
`secret.reloader.stakater.com/reload: "<secret-name>"` when the referenced object's
hash changes. Lets `ExternalSecret`-sourced credentials propagate to running pods without a
manual restart. INFRA-1502.

**Source.** Chart `stakater/reloader`. HelmRelease + namespace `reloader`.

**Key values / manifests.**

- `infrastructure/reloader/namespace.yaml`.
- `infrastructure/reloader/helmrelease.yaml` — default values, watching all namespaces.

**IRSA / dependencies.** None — cluster-local. Bound to a ClusterRole that watches
ConfigMaps + Secrets cluster-wide and patches Deployments / StatefulSets / DaemonSets.

**Verified state.** Deployment Ready; tested by rotating an `ExternalSecret`'s SM value and
confirming the consumer Deployment rolled within ~10s of the Secret update.

**Gotchas.**

- Reloader watches **all** namespaces by default. If you need to scope it down (e.g. to avoid
  rolling pods in privileged namespaces), set the chart's `reloader.watchGlobally: false`
  and provide a per-namespace allow-list.
- The `auto: "true"` annotation rolls on **any** change to **any** referenced CM/Secret. For
  surgical control, use the named annotation pointing at the specific Secret.

---

### istiod-health (`infrastructure/istiod-health/`)

**Purpose.** Periodic CronJob that probes istiod's cert chain and webhook serving cert, and
emits a metric / log line if it detects the recurring istiod cert drift documented in
`onprem_istiod_cert_drift_recurring` (memory). Detection-only — does not auto-remediate, only
flags so an operator can run the documented recovery procedure.

**Source.** Hand-rolled Kustomize. CronJob + ServiceAccount + RBAC.

**Key values / manifests.**

- `infrastructure/istiod-health/cronjob.yaml` — runs every 15 min, executes a small shell
  script that calls `openssl s_client` against istiod's webhook and parses the cert chain.
- `infrastructure/istiod-health/rbac.yaml` — `Role` granting `get` on Secrets in
  `istio-system` to read the in-cluster CA bundle for comparison.

**IRSA / dependencies.** None — cluster-local.

**Verified state.** CronJob runs; logs visible in Loki / kubectl. Cert drift has not
re-occurred since the last documented recovery; the alarm condition has not fired yet.

**Gotchas.** Detection-only; recovery requires manual operator action per the documented
procedure. Do NOT bolt on auto-remediation here without first finding the cert-drift root
cause — auto-remediation against an unknown root cause is how cascading cluster events start.

---

## Networking + TLS

### cert-manager (`infrastructure/cert-manager/`)

Purpose: The cert-manager controller HelmRelease — the controller that reconciles
`Issuer` / `ClusterIssuer` / `Certificate` CRs. CRDs install via the chart.
Source: Chart `jetstack/cert-manager`. HelmRelease + namespace `cert-manager`.
See: `cert-manager-issuers` for the actual issuers.

---

### cert-manager-issuers (`infrastructure/cert-manager-issuers/`)

Purpose: The Issuers themselves — `letsencrypt-prod-dns01` `ClusterIssuer` for the
`*.usxpress.io` wildcard, plus a self-signed root + internal CA chain used for in-cluster
serving certs (e.g. pod-identity-webhook), plus per-team `ClusterIssuer`s where teams need
their own ACME accounts. Phase 0 networking.
Source: Kustomize. ClusterIssuer + Certificate + ExternalSecret manifests.
See: `phase0_cert_manager_complete_may28`, `onprem_per_team_cert_pattern_may28` (memory).

---

### istio (`infrastructure/istio/`)

**Purpose.** istiod control plane + ingress gateway DaemonSet (hostPort-bound across workers,
no L4 LB) + MeshConfig. Phases 0/1/2 of on-prem networking are complete on top of this
component:

- **Phase 0**: cert-manager + Let's Encrypt wildcard `ClusterIssuer`. `*.usxpress.io` cert
  active and renewing.
- **Phase 1**: TCP / SNI listeners on the istio ingress gateway, hostPort-bound on the
  DaemonSet across all workers (no on-prem L4 LB; the L2 announcement is via worker
  hostNetwork).
- **Phase 2**: backend TLS via ghostunnel sidecar — apps that require mTLS to upstream get a
  ghostunnel sidecar injected; istio mesh handles the public-facing TLS.

**Source.** Charts from `istio` HelmRepository — `base` (CRDs), `istiod`, and the gateway
chart.

**Key values / manifests.**

```yaml
# infrastructure/istio/meshconfig.yaml (excerpt)
spec:
  meshConfig:
    defaultConfig:
      proxyMetadata: {}
    exportTo:
      - "*"        # CRITICAL — empty / unset blocks cross-ns VS visibility, RCA jun02
```

- `infrastructure/istio/base-helmrelease.yaml` — `istio/base` chart (CRDs).
- `infrastructure/istio/istiod-helmrelease.yaml` — `istio/istiod` chart, tied to the
  `istio-csr` cert-manager bridge.
- `infrastructure/istio/gateway-helmrelease.yaml` — `istio/gateway` chart in DaemonSet mode
  with `hostNetwork: true` and hostPort bindings on 80/443/15443.
- `infrastructure/istio/meshconfig.yaml` — `MeshConfig` with `exportTo: ["*"]`.

**IRSA / dependencies.**

- `istio-namespace` (the `istio-system` namespace must exist with the right PSA labels).
- `cert-manager` + `istio-csr` (istiod uses cert-manager-issued certs for the mesh CA via
  the `istio-csr` bridge).

**Verified state.**

- Root-zone wildcard cert active.
- Mesh `exportTo` confirmed across namespaces.
- Ambient HBONE working for app traffic (with the Bitnami chart NP exception called out
  below).
- istiod memory right-sized per `istiod_memory_rightsize_may28`.

**Gotchas.**

- MeshConfig `exportTo: ["*"]` is mandatory. Empty / unset blocks cross-namespace
  VirtualService visibility — root cause of the jun02 mesh incident.
- Bitnami charts ship a default-deny NetworkPolicy that blocks the ambient HBONE port —
  either disable the chart NP or extend it.
- istiod cert drift is a recurring incident class with a documented recovery procedure but
  no known root cause; `istiod-health` watches for it.

---

### istio-csr (`infrastructure/istio-csr/`)

Purpose: The `cert-manager-istio-csr` bridge — runs the gRPC server istiod talks to for mesh
CA cert issuance, backed by a cert-manager `Issuer`. Replaces istiod's self-signed mesh CA
with a cert-manager-managed chain.
Source: Chart `jetstack/cert-manager-istio-csr`. HelmRelease + HelmRepository + values.

---

### istio-ingress (`infrastructure/istio-ingress/`)

Purpose: The `Gateway` + `VirtualService` primitives that live at the ingress edge — includes
`brands-cert` Certificate, `cnp-allow-corp-vpn-to-gateway` CNP, and the
`gateway-tcp-passthrough` Gateway for SNI passthrough listeners. Per-team VS / Gateway
content lives in component-specific dirs (e.g. `risingwave-routes`); platform-level edge
glue lives here.
Source: Kustomize.
See: `onprem_gateway_dns_cert_layout_jun03`, `phase1_tcp_sni_listeners_done_jun01` (memory).

---

### istio-namespace (`infrastructure/istio-namespace/`)

Purpose: The `istio-system` namespace declaration + PSA labels (`baseline` enforce — istiod
runs with `runAsNonRoot: true` but pulls in volumes that PSA-restricted blocks). Standalone
so it can be reconciled before `istio` itself depends on it.
Source: Kustomize.

---

### external-dns (`infrastructure/external-dns/`)

**Purpose.** Sync `Service` and `Ingress` / `Gateway` hostnames into Route 53 hosted zones
(`*.usxpress.io` for the root zone, plus per-team subzones). On-prem external traffic flows in
through the istio ingress gateway's hostPort + DaemonSet; external-dns publishes the workers'
IPs as A records for the relevant FQDNs.

**Source.** Chart `external-dns` **v0.20.0**.

**Key values / manifests.**

```yaml
# infrastructure/external-dns/helmrelease.yaml (excerpt)
spec:
  values:
    image:
      tag: v0.20.0
    provider: aws
    aws:
      region: us-east-2
    serviceAccount:
      create: true
      name: external-dns
      annotations:
        eks.amazonaws.com/role-arn: arn:aws:iam::700736442855:role/op-usxpress-dev-external-dns
    domainFilters:
      - usxpress.io
    policy: sync
    txtOwnerId: op-usxpress-dev
    sources:
      - service
      - ingress
      - istio-virtualservice
    extraArgs:
      - --target=<gateway-LB-IP-or-ALB>     # v0.20.0 REQUIRES --target — NOT --host
```

**IRSA / dependencies.** SA `external-dns/external-dns` assumes
`op-usxpress-dev-external-dns` (Route 53 hosted-zone trust scoped to the parent account).
Depends on `pod-identity-webhook` being healthy so IRSA env injection works.

**Verified state.** A records for the on-prem `rw2-dashboard` + `rw2-sql-passthrough`
hostnames published; TXT ownership records carry `op-usxpress-dev` so a stray external-dns
elsewhere will not stomp them.

**Marathon issue.** On first `Pod` create after the SA flipped to IRSA, the pod-identity
webhook failed to inject `AWS_ROLE_ARN` (mutating webhook race against the SA's annotation
patch). A `pod delete` was enough to retrigger mutation — **no IaC change was required**, but
a follow-up Kyverno policy that watches for SAs with the IRSA annotation but no corresponding
env on the pod is tracked under INFRA-1555 (deferred).

**Gotchas.**

- v0.20.0 broke the `--host` flag — use `--target` or external-dns silently never publishes.
  See the catalog entry `externaldns-target-required`.
- Confirm `txtOwnerId` matches the cluster name before opening up `domainFilters` wider —
  collisions with the cloud external-dns will eat each other's TXTs.

---

### trust-manager (`infrastructure/trust-manager/`)

Purpose: The jetstack trust-manager controller HelmRelease — reconciles `Bundle` CRs to
distribute CA bundles to namespaces.
Source: Chart `jetstack/trust-manager`. HelmRelease + namespace.

---

### trust-manager-bundle (`infrastructure/trust-manager-bundle/`)

Purpose: The actual `Bundle` CR consumed by trust-manager. Distributes the corporate CA
chain + the internal selfsigned-root CA to consumer namespaces so workloads can validate
intra-cluster + corp-issued TLS without bind-mounting their own ca-bundle.
Source: Kustomize. `Bundle` CR.

---

### risingwave-routes (`infrastructure/risingwave-routes/`)

Purpose: The `VirtualService` + `Certificate` set for the rw-2 cluster — `rw2-dashboard`
(HTTPS, terminates at istio), `rw2-overview` (HTTPS), and `rw2-sql-passthrough` (TCP/SNI
passthrough to the RW-2 frontend on the dedicated SNI listener).
Source: Kustomize. VirtualServices + Certificate.
See: `onprem_gateway_dns_cert_layout_jun03` (memory).

---

## CI/CD + autoscaling

### arc-controller (`infrastructure/arc-controller/`)

**Purpose.** Actions Runner Controller — the controller half of the GitHub Actions self-hosted
runner system. Watches `AutoscalingRunnerSet` CRs and provisions runner pods on demand,
talking to the GitHub API to register them as ephemeral runners against the
`Knight-Swift-Inc-Cloud` (or per-org) GitHub org. Companion to the per-pool runner
directories (e.g. `arc-runner-rw-pipeline`).

**Source.** Chart `actions-runner-controller/gha-runner-scale-set-controller` (the official
ARC v2 controller). HelmRepository + HelmRelease + Kustomization + namespace `arc-systems`.

**Key values / manifests.**

- `infrastructure/arc-controller/namespace.yaml` — `arc-systems`, PSA-restricted.
- `infrastructure/arc-controller/helmrepository.yaml` — points at the official ARC OCI
  registry.
- `infrastructure/arc-controller/helmrelease.yaml` — chart values: controller resource
  requests/limits, cert-manager-issued webhook cert config, watchSingleNamespace off so
  multiple runner-set namespaces can be served.

**IRSA / dependencies.**

- `cert-manager` (webhook TLS).
- No AWS IRSA — runner GitHub auth uses a GitHub App private key sourced via ExternalSecret
  in the per-pool directories.

**Verified state.**

- Controller Deployment Ready in `arc-systems`.
- Webhook serving cert green.
- `arc-runner-rw-pipeline` runner pool registers ephemeral runners against the GitHub org
  on demand.

**Gotchas.**

- ARC v2 (the `gha-runner-scale-set-controller`) is **not** API-compatible with the older
  `actions-runner-controller` v0.x — do not mix them.
- The controller and the runner pool are deployed as two separate Flux Kustomizations so a
  runner-pool config error does not roll back the controller.

---

### arc-runner-rw-pipeline (`infrastructure/arc-runner-rw-pipeline/`)

**Purpose.** A dedicated self-hosted ARC runner pool that executes the RW (RisingWave)
SQL-pipeline GitHub Actions workflows inside the on-prem cluster. The runners need cluster
reach (to talk to `risingwave-2`'s SQL endpoint over the in-cluster mesh) and corp-network
reach (to pull schemas from internal git mirrors), which is why they live on-prem rather
than on GitHub-hosted runners.

**Source.** Hand-rolled Kustomize wrapping the ARC v2
`AutoscalingRunnerSet` CR + an `ExternalSecret` for the GitHub App credentials + a namespace
`arc-runner-rw-pipeline`.

**Key values / manifests.**

- `infrastructure/arc-runner-rw-pipeline/namespace.yaml` — `arc-runner-rw-pipeline`,
  PSA-restricted.
- `infrastructure/arc-runner-rw-pipeline/externalsecret.yaml` — pulls the GitHub App
  private key from AWS SM `op-usxpress-dev/arc-runner-rw-pipeline/github-app-key`.
- `infrastructure/arc-runner-rw-pipeline/autoscalingrunnerset.yaml` — `AutoscalingRunnerSet`
  CR scoped to the GitHub org / repo, min/max runners, resource requests, and tolerations
  for worker nodes.

**IRSA / dependencies.**

- `external-secrets-config` (GitHub App key ExternalSecret).
- `arc-controller` (reconciles the AutoscalingRunnerSet CR).
- No AWS IRSA — runner GitHub auth is bearer-token / App-key, not IRSA.

**Verified state.**

- Runner pool registered against the GitHub org.
- SQL-pipeline workflow runs picked up by an on-prem ephemeral runner; pod created → workflow
  ran → pod destroyed cleanly.
- See `arc_runner_deploy_state_may27` (memory) for the original deploy notes.

**Gotchas.**

- The GitHub App private key in SM is a PEM block — `ExternalSecret` carries
  `dataFrom.extract` with key remapping rather than `data[].secretKey` so the multi-line PEM
  survives JSON escape unmangled.
- ARC runner pods are ephemeral; do not expect to `kubectl exec` into one for debugging —
  it will be gone by the time you attach. Capture logs via the workflow run output instead.

---

### octopus-worker (`infrastructure/octopus-worker/`)

**Purpose.** An in-cluster Octopus Deploy tentacle, running as a pod with persistent
identity. Lets Octopus drive runbooks and Terraform applies that need to execute from inside
the cluster (e.g. against the kube API, against in-cluster Secrets) without exposing the
kube API externally to a standalone worker. Currently used for in-cluster TF apply for
certain projects where the standalone Octopus worker pool would require corp-network reach
that is not available outside the cluster.

**Source.** Chart (Octopus's tentacle chart) wrapped in a HelmRelease, plus a ConfigMap that
templates the tentacle config (`Octopus.Server.Endpoint`, `Space`, `WorkerPool`, etc.).

**Key values / manifests.**

- `infrastructure/octopus-worker/namespace.yaml` — `octopus-worker` namespace.
- `infrastructure/octopus-worker/helmrelease.yaml` — chart values: image, resource requests,
  persistent volume on `ceph-block` for tentacle state.
- `infrastructure/octopus-worker/configmap.yaml` — tentacle connection config templated to
  point at the Knight-Swift Octopus instance and the appropriate Space / Worker Pool.
- `infrastructure/octopus-worker/externalsecret.yaml` — pulls the Octopus API key from AWS
  SM `op-usxpress-dev/octopus-worker/api-key`.

**IRSA / dependencies.**

- `external-secrets-config` (Octopus API key).
- `rook-ceph-cluster` (PVC for tentacle state).
- No AWS IRSA at the worker level — though the projects the worker runs may themselves use
  IRSA when applying TF for in-cluster IAM-using workloads.

**Verified state.**

- Tentacle pod Ready; registered against the Octopus instance as a worker.
- Test runbook executes against the in-cluster kube API.

**Gotchas.**

- The Octopus Space + Worker Pool must exist on the Octopus side before the tentacle can
  register. This is gated by INFRA-1535 / INFRA-1543 (Octopus admin tickets) — see external
  blockers.
- Do **not** point this worker at any cloud-side project that has IRSA credentials — the
  on-prem cluster's IRSA role trust is scoped to USX-Dev, not the cross-account roles
  cloud-side projects assume.

---

### keda (`infrastructure/keda/`)

Purpose: KEDA event-driven autoscaler — scales workloads on external metrics
(queue depth, Prometheus query, etc.). Companion to HPA for non-CPU/memory triggers.
Source: Chart `kedacore/keda`. HelmRelease + Kustomization + namespace `keda`.

---

## Policy

### kyverno (`infrastructure/kyverno/`)

**Purpose.** The Kyverno policy engine controller — runs the admission webhook and the
background scan controller that evaluate `ClusterPolicy` / `Policy` objects against incoming
admission requests and existing resources.

**Source.** Chart `kyverno/kyverno`. HelmRelease + Kustomization + namespace `kyverno`.

**Key values / manifests.**

- `infrastructure/kyverno/namespace.yaml`.
- `infrastructure/kyverno/helmrelease.yaml` — chart with admission webhook in `failurePolicy:
  Ignore` mode (so a Kyverno outage degrades policy enforcement but does not block all
  cluster admission).

**IRSA / dependencies.** None. Depends on `cert-manager` for the webhook serving cert when
the chart is configured to use it.

**Verified state.** Controller Deployment Ready; webhook serving cert green; `ClusterPolicy`
CRs from `kyverno-policies` evaluated against new admission requests.

**Gotchas.**

- `failurePolicy: Ignore` is a deliberate trade-off — a Kyverno outage during, say, a node
  restart should not cascade into a cluster-wide admission outage. Match this with monitoring
  on the Kyverno controller's `Ready` state so the silent-skip is alerted.
- Background policy scans run on a schedule; mutations/validations applied at admission time
  are NOT retroactively applied to pre-existing resources unless the policy is reconciled.

---

### kyverno-policies (`infrastructure/kyverno-policies/`)

**Purpose.** The actual `ClusterPolicy` CRs. Mix of mutations (add labels, inject env) and
validations (require runAsNonRoot, deny `:latest` tags). Companion to `kyverno`.

**Source.** Hand-rolled Kustomize. One YAML per policy.

**Key values / manifests.**

- `infrastructure/kyverno-policies/auto-grafana-folder-label.yaml` — mutation: when a
  `ConfigMap` with the `grafana_dashboard` label is created without a folder label, inject
  the right folder label based on the dashboard's namespace.
- `infrastructure/kyverno-policies/policy-mongo-atlas.yaml` — validation: enforce mongo-atlas
  workload conventions (the v2 architectural pattern — required annotations, SA naming, etc.).
- Future entries (deferred under INFRA-1555 and similar tickets) will add validations for
  IRSA SA orphaning, missing PSA seccompProfile, and the cross-cluster CSS source-pinning
  pattern.

**IRSA / dependencies.** None directly — `kyverno` must be Ready first (its
`Kustomization` carries `dependsOn: [name: kyverno]`).

**Verified state.** Policies evaluated at admission time. The `auto-grafana-folder-label`
mutation observed re-labeling new dashboard CMs as they appeared.

**Gotchas.**

- New policies should start in `validationFailureAction: audit` mode and only flip to
  `enforce` after a clean background-scan run shows no existing offenders. Flipping to
  `enforce` on a policy with existing offenders breaks the next admission attempt against
  those resources.

---

## Recent additions — jun23 marathon

Nine PRs landed on `op-dev` during the 2026-06-23 marathon close-out. Listed in merge order;
each corresponds to a section above.

| PR  | Component             | Change                                                                                              |
|-----|-----------------------|-----------------------------------------------------------------------------------------------------|
| #54 | rook-ceph-cluster     | `CephCluster.spec.resources.mgr.limits.memory: 2Gi` (was default 512Mi; mgr was OOMKilling 135×/16h) |
| #55 | velero                | Override `kubectl.image.repository: bitnamilegacy/kubectl` tag `1.32` (Bitnami removed versioned tags) |
| #56 | prometheus            | `storageSpec.volumeClaimTemplate.spec.storageClassName: ceph-block` (was emptyDir; lost 4.9 GiB / restart) |
| #57 | rook-ceph-cluster     | Toolbox always-on `Deployment` (chart toggle) — required for ad-hoc `ceph` CLI                       |
| #58 | etcd-backup           | PSA-restricted `seccompProfile: RuntimeDefault` on pod spec (Job was retrying forever silently)      |
| #59 | velero                | Add `AWS_REGION=us-east-2` via `configuration.extraEnvVars` (Kopia STS call needs it)                |
| #60 | velero                | Remove `nodeAgent.extraEnvVars` duplicate — chart renders BOTH onto the node-agent DS; SSA dup-key rollback |
| #61 | etcd-backup           | Multi-container restructure: distroless `talosctl` initContainer + `aws-cli` main + shared emptyDir `/work` |
| #62 | etcd-backup           | Memory bump: initContainer 256Mi → 1Gi (tmpfs accounting was eating into the limit on a 287 MiB snapshot) |

The set covers the marathon umbrella ticket **INFRA-1544** and individual tickets
**INFRA-1545 through INFRA-1554** (see [Tickets](#tickets) at the bottom). Default branch flip
from `prod` to `op-dev` also happened in this window — performed in the GitHub repo settings
under Branches.

---

## IRSA dependency graph

Every IRSA SA in this repo points at a role defined in
[`variant-inc/iaac-talos`](https://github.com/variant-inc/iaac-talos) under `modules/irsa/<name>`.
The role's OIDC trust uses the cluster's OIDC provider (registered in the same Terraform).
Roles live in account **`700736442855` (USX-Dev)** for the dev cluster; the QA / prod brings
follow the account map.

| Component                 | SA namespace/name              | IRSA role (USX-Dev)                       | iaac-talos module             |
|---------------------------|--------------------------------|-------------------------------------------|-------------------------------|
| velero                    | `velero/velero`                | `op-usxpress-dev-velero`                  | `modules/irsa/velero`         |
| etcd-backup               | `etcd-backup/etcd-backup`      | `op-usxpress-dev-etcd-backup`             | `modules/irsa/etcd-backup`    |
| external-dns              | `external-dns/external-dns`    | `op-usxpress-dev-external-dns`            | `modules/irsa/external-dns`   |
| external-secrets (default)| `external-secrets/external-secrets` | `op-usxpress-dev-external-secrets`   | `modules/irsa/external-secrets`|
| cert-manager (DNS-01)     | `cert-manager/cert-manager`    | `op-usxpress-dev-cert-manager`            | `modules/irsa/cert-manager`   |
| ecr-credentials           | `ecr-credentials/ecr-credentials` | `op-usxpress-dev-ecr-credentials`      | `modules/irsa/ecr-credentials`|
| pod-identity-webhook      | n/a — webhook is what makes IRSA work | —                                  | —                             |
| prometheus                | n/a — no AWS calls             | —                                         | —                             |
| grafana                   | n/a — no AWS calls (SM via ESO)| —                                         | —                             |
| rook-ceph-operator        | n/a — cluster-local            | —                                         | —                             |
| rook-ceph-cluster         | n/a — cluster-local            | —                                         | —                             |
| arc-controller            | n/a — GitHub App key, not IRSA | —                                         | —                             |
| arc-runner-rw-pipeline    | n/a — GitHub App key, not IRSA | —                                         | —                             |
| octopus-worker            | n/a — Octopus API key, not IRSA| —                                         | —                             |

The `cross-cluster-eso` CSS is **not IRSA** — it carries a kubeconfig-style bearer token
seeded by the Octopus bootstrap runbook.

**Bring-up order matters**: the IRSA role must exist in AWS before the SA reconciles, or the
first pod will fail STS AssumeRole. The `iaac-talos` Terraform run is therefore a hard
prerequisite for any `infrastructure/<component>/` Kustomization that uses IRSA. For new
clusters, run `terraform apply` in `iaac-talos` to completion **before** the matching branch
in this repo is created.

Also note: `pod-identity-webhook` is the load-bearing piece that **makes IRSA work** on a
non-EKS cluster. Without it, the IRSA SA annotations are inert. Its `Kustomization` must
sequence before any IRSA-consuming component reconciles.

---

## PSA awareness

All component namespaces in this repo enforce `PodSecurity: restricted` baseline-of-baselines,
with the explicit exceptions documented below. Any pod spec landing in this repo must
therefore:

- Set `securityContext.runAsNonRoot: true`.
- Set `securityContext.seccompProfile.type: RuntimeDefault` at the pod (and ideally container)
  level. **A missing seccompProfile under PSA-restricted causes a `Job` to retry forever
  silently** — the controller never marks the Job failed because the admission failure is
  per-Pod, and a new Pod is created on each retry. The `etcd-backup` CronJob fell into this
  trap before PR #58.
- Drop all capabilities (`securityContext.capabilities.drop: [ALL]`).
- Set `allowPrivilegeEscalation: false`.
- Set `runAsUser` and `runAsGroup` to non-zero IDs.

PSA exceptions in this repo:

- `rook-ceph` namespace (under `rook-ceph-operator`) — `privileged` enforce. Rook OSDs,
  CSI provisioners, and the OSD-prepare Jobs need privileged + hostPath access.
- `istio-system` namespace (under `istio-namespace`) — `baseline` enforce. istiod and the
  ingress gateway need volume types PSA-restricted blocks.
- `infrastructure/rook-recovery-jobs/osd-wipe.yaml` is privileged by design and runs in
  `rook-ceph`. Manual-apply only; Flux does not own it.

---

## Velero gotcha catalog

Three traps specific to Velero, all of which we hit during the marathon. Worth a dedicated
section because they re-trigger silently and the failure mode does not look like a Velero
problem.

### 1. The duplicate-extraEnvVars trap

The Bitnami Velero chart, given:

```yaml
configuration:
  extraEnvVars:
    - { name: AWS_REGION, value: us-east-2 }
nodeAgent:
  extraEnvVars:
    - { name: AWS_REGION, value: us-east-2 }
```

renders the **first block onto the node-agent DaemonSet as well**, producing two env entries
with the same key. Server-side apply rejects this with a duplicate-key error. The helm
release silently rolls back to the previous revision and `HelmRelease.status` shows `Ready`
because the rollback succeeded. The symptom is "my new env vars never showed up" with no
error in `flux get helmreleases` and no error in the Pod.

**Fix**: only set `configuration.extraEnvVars`. Do not set `nodeAgent.extraEnvVars`. Verified
in PR #60.

### 2. Kopia AWS_REGION requirement

Kopia inside the node-agent makes its **own STS AssumeRole** — separate from the IRSA flow
that the velero server pod uses to talk to S3 and EC2. That STS call resolves the regional
endpoint from `AWS_REGION` env, **not** from the BSL `config.region` field. The BSL config
gets the bucket the wrong endpoint and you see:

```
sts..amazonaws.com               <- DOUBLE-DOT — telltale of empty region
```

in node-agent logs. The fix is `AWS_REGION` as an env var on every container that runs Kopia,
landed via `configuration.extraEnvVars` in PR #59.

### 3. Bitnami legacy migration (bitnamilegacy/*)

On 2026-06-19 Bitnami removed versioned tags from `bitnami/*` images on Docker Hub. The
Velero chart pins `bitnami/kubectl:<minor>` for its kubectl image. Result:

```
ImagePullBackOff: bitnami/kubectl:1.32: manifest unknown
```

Override the kubectl image registry+repository to `bitnamilegacy/kubectl` and pin the tag.
Apply the same override to the velero image itself if the chart hands you any
`bitnami/velero:<minor>` defaults. PR #55.

This trap is not Velero-specific — anything pulling from `bitnami/*` with a minor-version tag
404s. Migrate to `bitnamilegacy/*` until the chart upstream switches.

---

## etcd-backup multi-container pattern

The `etcd-backup` CronJob is structured as **initContainer (talosctl) + main container
(aws-cli) + shared emptyDir at /work**. The non-obvious bits:

### Why distroless talosctl forces multi-container

`ghcr.io/siderolabs/talosctl:v1.10.4` is a distroless image — there is no `/bin/sh`, no
`bash`, no `aws` CLI inside it. A single-container Job that tried to chain
`talosctl etcd snapshot ... && aws s3 cp ...` was a non-starter: there is no shell to run the
chain in.

Pattern: run `talosctl` as an initContainer with only its native binary as `command`, write
the snapshot to a shared `emptyDir` volume, then run the main container (`amazon/aws-cli`)
with a `bash` script that uploads the file. Both containers share the volume; the
initContainer-vs-main ordering gives us the chain semantics without a shell.

### Why workdir is NOT on tmpfs

The shared volume was initially declared as `emptyDir: { medium: Memory }`. tmpfs counts
against the **pod's** memory limit, so writing a 287 MiB snapshot to a tmpfs volume with a
1 GiB pod memory limit ate into talosctl's own memory budget. talosctl was OOMKilled at 256Mi
limit when the snapshot was barely halfway written.

Fix: drop `medium: Memory` so the emptyDir lands on the node's filesystem (containerd's
graph driver). Plus a `sizeLimit: 2Gi` so a runaway snapshot cannot fill the node.

### Memory sizing

The initContainer memory limit was bumped to 1 GiB in PR #62. Rationale:

- 287 MiB current snapshot, growing as cluster state grows.
- talosctl itself allocates working buffers proportional to the snapshot.
- Headroom for one snapshot worth of growth without re-tuning every quarter.

The main `upload` container stays at 256 MiB — it streams the file out via `aws s3 cp` and
never holds the whole file in memory.

### Talosconfig provisioning

The `talosconfig` secret in-cluster is hydrated by an `ExternalSecret` pointing at AWS SM
`op-usxpress-dev/talosconfig`. The SM secret itself is **imported into Terraform state by ARN**
(not name) — see the iaac-talos README. The pod mounts the secret read-only at `/etc/talos/`
with mode `0400`.

---

## Per-cluster bring-up

When cloning this repo's content to a new cluster (e.g. QA):

1. **Branch.** Cut a new branch off `op-dev` at the current green commit. Name it after the
   cluster: `qa-dev` for the dev-QA cluster, `op-prod` for prod when its time comes.
2. **IRSA precondition.** Every IRSA role this repo references must exist in the target
   account **before** Flux on the new cluster starts reconciling. Run `iaac-talos`
   `terraform apply` for the new cluster module to completion first. Validate with
   `aws iam get-role --role-name <cluster>-velero` and friends.
3. **Search-replace per-cluster identifiers.** Touch every `HelmRelease` and hand-rolled
   manifest:
   - S3 bucket names: `velero-op-usxpress-dev` → `velero-<cluster>`
   - S3 prefixes:     `etcd-snapshots-op-usxpress-dev/op-usxpress-dev/*` → `<cluster>/<cluster>/*`
   - IRSA role ARNs in SA annotations
   - AWS region (if cluster lives in a different region)
   - Route 53 `domainFilters` and `txtOwnerId` in `external-dns`
   - `endpoints`/`nodes` IPs in the etcd-backup CronJob (Talos API VIP of the new cluster)
   - cert-manager `ClusterIssuer` email
   - GitHub org / runner-pool scoping in `arc-runner-rw-pipeline`
   - Octopus Space / Worker Pool in `octopus-worker`
4. **Cross-cluster ESO seed.** The Octopus bootstrap runbook seeds the cross-cluster token
   AFTER Flux is up. Skip cross-cluster ESO entirely if the new cluster does not need
   cloud-side secrets.
5. **Add Flux pointers.** In `iaac-talos-flux-cluster`, add a per-cluster
   `Kustomization`/`GitRepository` pair referencing the new branch. Sequence the
   Kustomizations so `pod-identity-webhook` reconciles before any IRSA-consuming component.
6. **Watch the first reconcile.** `flux get kustomizations -A -w` — anything sitting in
   `Reconciling` past 10 minutes is a problem (see Flux kstatus gotcha).

Do **not** copy the cluster directory in `iaac-talos-flux-cluster` between repos as a
"template" — re-derive from `op-dev` so component additions since the last clone come along.

---

## Operational runbooks

Detailed troubleshooting catalog lives in the enterprise iaac-talos repo:
[`variant-inc/iaac-talos:deploy/docs/troubleshooting/`](https://github.com/variant-inc/iaac-talos/tree/feature/op-usxpress-dev/deploy/docs/troubleshooting).
Quick index of the runbooks most relevant to this repo:

- `cp-oom-cascade.md` — recovery using the etcd-backup snapshot from S3 + talosctl bootstrap
- `flux-kstatus-terminal-failure.md` — the 32-day cascade RCA
- `rook-toolbox-required.md` — when ceph CLI is needed and the operator pod has no shell
- `bluestore-label-sot.md` — never re-label a device with a bluestore label
- `ceph-mgr-memory-default-too-small.md` — the 512Mi → 2Gi bump
- `risingwave-operator-chart-missing-cluster-rbac.md` — supplemental ClusterRole pattern
- `velero-chart-extra-env-duplicate.md` — the dup-extraEnvVars trap above
- `velero-irsa-kopia-aws-region.md` — `sts..amazonaws.com` telltale
- `psa-restricted-seccomp-required.md` — silent Job retry trap
- `talosctl-image-distroless.md` — why etcd-backup is multi-container
- `aws-secretsmanager-secret-import-arn.md` — import by ARN, not name
- `externaldns-target-required.md` — v0.20.0 `--target` flag
- `bitnami-legacy-migration.md` — `bitnami/*` minor-tag 404s
- `pod-identity-webhook-irsa-race.md` — `pod delete` to re-trigger mutation after late SA annotation
- `istiod-cert-drift-recovery.md` — recurring incident class; documented recovery, RC unknown
- `cilium-node-reconciler.md` — 4 divergence modes the hygiene CronJob remediates

The `/onprem-troubleshooting` skill in the Cloud Platform agent harness surfaces these from
the catalog.

---

## Common gotchas

A condensed list of the cross-cutting traps that have bitten us in this repo; each links to a
fuller writeup in the enterprise troubleshooting catalog.

- **Flux kstatus terminal-failure = settled.** A `Kustomization` whose
  `status.conditions[Reconciled].reason == "BuildFailed"` is **not retried**. Caused a
  32-day cascade. Verify with `flux get kustomizations -A | grep -v True` periodically.
- **Bitnami legacy migration.** `bitnami/*` versioned tags 404 — switch to `bitnamilegacy/*`.
- **Bitnami chart NetworkPolicy blocks ambient HBONE.** Bitnami charts ship a default-deny NP;
  ambient HBONE traffic gets dropped. Disable the chart NP or extend it.
- **external-dns v0.20.0 requires `--target`.** The `--host` flag is gone in v0.20.0; pods
  appear healthy but no records are published.
- **MeshConfig `exportTo: ["*"]` is mandatory.** Empty / unset blocks cross-namespace
  VirtualService visibility — root cause of the jun02 mesh incident.
- **Rook-Ceph toolbox required.** The operator pod has no `ceph` CLI; the toolbox Deployment
  must be always-on for ad-hoc inspection.
- **Bluestore label = SOT for OSD identity.** Never re-label a device with an existing
  bluestore label — you will lose the OSD's data.
- **AWS SM secret import needs ARN.** Terraform `import` for AWS Secrets Manager rejects the
  secret name; the import block must reference the ARN. Get it with
  `aws secretsmanager describe-secret --query ARN`.
- **`sed` range patterns must anchor leading whitespace** when editing indented YAML, e.g.
  `/^  name:/` not `/name:/`.
- **PSA restricted requires `seccompProfile`.** A Job missing it retries forever silently.
- **talosctl image is distroless.** No `/bin/sh`, no shell-glue — use the multi-container
  pattern with a shared `emptyDir`.
- **pod-identity-webhook is what makes IRSA work.** On Talos / non-EKS clusters, IRSA SA
  annotations are inert without the webhook. If IRSA-annotated SAs do not produce pods with
  `AWS_ROLE_ARN`, check the webhook is Ready first — then `kubectl delete pod` to re-trigger
  mutation against the existing SA.
- **Cross-cluster CSS is a SPOF.** POC-only pattern; migrate prod-grade workloads to a
  default-CSS-friendly secret source.
- **Kyverno `failurePolicy: Ignore` is deliberate.** A Kyverno outage degrades policy
  enforcement but does not block cluster admission. Monitor the Kyverno controller's
  `Ready` state.

---

## Related repos

- [`variant-inc/iaac-talos`](https://github.com/variant-inc/iaac-talos) — Talos cluster
  bootstrap (Terraform + machine config + IRSA roles). Default base branch for on-prem PRs:
  `feature/op-usxpress-dev` (NOT `master`).
- [`variant-inc/iaac-talos-flux-cluster`](https://github.com/variant-inc/iaac-talos-flux-cluster)
  — per-cluster Flux entry-points; the consumer of this repo. Each cluster's `clusters/<name>/`
  declares `Kustomization`s pointing at our `infrastructure/<component>/` paths.
- [`variant-inc/iaac-risingwave-2`](https://github.com/variant-inc/iaac-risingwave-2) — RW-2
  manifests. Lives in its own repo to keep app-team velocity decoupled from the platform layer.
  Consumes the `external-secrets-config` default CSS and the `ceph-block` SC defined here,
  plus the `risingwave-routes` VirtualServices for ingress.
- [`variant-inc/iaac-octopus-onprem`](https://github.com/variant-inc/iaac-octopus-onprem) —
  Octopus Deploy on-prem TF + runbooks. Drives the `octopus-worker` and seeds the
  `cross-cluster-eso` token.

---

## Tickets

Marathon umbrella + individual line items, all under the **INFRA** project on the
Knight-Swift Jira instance.

| Ticket       | Status     | Summary                                                                 |
|--------------|------------|-------------------------------------------------------------------------|
| INFRA-1544   | done       | jun23 marathon umbrella (Velero + etcd-backup + Prom on Ceph + mgr OOM)  |
| INFRA-1545   | done       | Velero kubectl image override to `bitnamilegacy/kubectl:1.32`            |
| INFRA-1546   | done       | Velero AWS_REGION via `configuration.extraEnvVars`                       |
| INFRA-1547   | done       | Velero remove `nodeAgent.extraEnvVars` duplicate                         |
| INFRA-1548   | done       | Velero daily-full schedule + 14d retention + restore proof               |
| INFRA-1549   | done       | etcd-backup PSA seccompProfile RuntimeDefault                            |
| INFRA-1550   | done       | etcd-backup multi-container talosctl + aws-cli + shared emptyDir         |
| INFRA-1551   | done       | etcd-backup initContainer memory 256Mi → 1Gi                             |
| INFRA-1552   | done       | Prometheus storageSpec → ceph-block (was emptyDir)                       |
| INFRA-1553   | done       | CephCluster mgr memory 512Mi → 2Gi                                       |
| INFRA-1554   | done       | rook-ceph toolbox always-on Deployment                                   |
| INFRA-1555   | deferred   | Kyverno mutation policy for orphaned IRSA SAs (external-dns pod-id race) |
| INFRA-1502   | done       | Reloader for ConfigMap/Secret-driven Deployment rolls                    |
| INFRA-1520   | done       | Grafana observability Phase 4                                            |

External blockers tracked outside this repo's PRs but adjacent to the marathon:

- **INFRA-1545 (Tim)** — RW-2 SQL pipeline final wiring.
- **INFRA-1535 / 1543 (Octopus admin)** — Octopus space + role wiring for OnPremise; gates
  `octopus-worker` final registration.
- **TF state cross-region (cloud-ops)** — moving `iaac-talos` Terraform state replication.

---

_Owner: Cloud Platform Team, Knight-Swift._
_Branch source-of-truth: `op-dev` for `op-usxpress-dev`._
_Questions: ping the Cloud Platform Team Slack channel; for on-prem outages page via
PagerDuty + Freshservice ticket._

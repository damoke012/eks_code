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
│   ├── cert-manager/                               cert-manager + LE wildcard ClusterIssuer
│   ├── cilium-node-reconciler/                     CronJob that heals 4 divergence modes
│   ├── cross-cluster-eso/                          ESO bridge for cloud-EKS-source secrets
│   ├── etcd-backup/                                hourly talosctl etcd snapshot → S3
│   ├── external-dns/                               Route 53 sync, IRSA-based
│   ├── external-secrets-config/                    default ClusterSecretStore → AWS SM
│   ├── istio/                                      istiod + ingress gateway + MeshConfig
│   ├── kyverno/                                    cluster policies (IRSA-mutation, PSA defaults)
│   ├── prometheus/                                 kube-prometheus-stack, ceph-block backed
│   ├── reloader/                                   stakater reloader for ConfigMap/Secret churn
│   ├── rook-ceph/                                  rook operator + CephCluster + ceph-block SC
│   ├── rook-recovery-jobs/                         manual-apply destructive/diagnostic templates
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

### Velero (`infrastructure/velero/`)

**Purpose.** Cluster-wide PVC + manifest backup, Kopia file-system snapshot mode, S3-backed,
IRSA auth. Backs up everything in the cluster minus `kube-system` and `flux-system` (Flux is
the source of truth for those — restoring stale objects from a snapshot would fight the
reconciler).

**Chart / source.** `bitnamilegacy/velero` (was `bitnami/velero` until Bitnami removed
versioned tags from `bitnami/*` on 2026-06-19; see common gotchas).

**Key values.**

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

**IRSA dependencies.** ServiceAccount `velero/velero` annotated with the IAM role created by
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

**Chart / source.** Hand-rolled Kustomize — no chart. A chart for this would be over-engineering
for a single resource.

**Manifests.**

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

**IRSA dependencies.** ServiceAccount `etcd-backup/etcd-backup` assumes the role provisioned
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

### Prometheus (`infrastructure/prometheus/`)

**Purpose.** kube-prometheus-stack (Prom + Alertmanager + node-exporter + kube-state-metrics)
scraping the on-prem cluster. Mirror of the cloud `iaac-monitoring` topology, scoped down to
what an on-prem cluster needs (no remote-write yet — that lands in observability Phase 6).

**Chart / source.** `prometheus-community/kube-prometheus-stack`.

**Key values.**

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

**IRSA dependencies.** None — Prometheus runs cluster-local; no AWS calls.

**Verified state.** PVC bound to a `ceph-block` RBD volume, Prom Running, TSDB persisted
across a pod restart, RW-2 also moved its Prometheus-server PVC to `ceph-block` as the second
customer on the SC.

**Gotchas.** `retentionSize` must be slightly less than the PVC `storage` request so that
WAL + head + index headroom does not bump into the PVC limit (`retentionSize` is steady-state
on-disk, not peak).

---

### Rook-Ceph (`infrastructure/rook-ceph/`)

**Purpose.** Rook operator plus a single in-cluster `CephCluster` providing the `ceph-block`
RBD `StorageClass`. ~350 GiB of usable block storage across the worker OSDs; sized for the
RW-2 Prometheus + state stores plus the first wave of cluster-local persistent workloads.

**Chart / source.** Rook chart for the operator; hand-rolled `CephCluster` /
`CephBlockPool` / `StorageClass` manifests for the cluster spec.

**Key values.**

```yaml
# infrastructure/rook-ceph/cephcluster.yaml (excerpt)
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

**IRSA dependencies.** None — Rook-Ceph runs cluster-local.

**Verified state.**
- `ceph-block` `StorageClass` registered, default for the cluster.
- ~350 GiB usable; 4 OSDs healthy across workers.
- mgr no longer OOM-killing after the 2 GiB bump (was at 135 OOMs in 16h pre-PR #54).
- toolbox always-on `Deployment` available for ad-hoc `ceph` CLI — required because the
  operator pod does not carry the CLI in a shell-shaped image.

**Gotchas.**
- The bluestore label on each OSD device is the **source of truth** for OSD identity — never
  re-label a device that already carries a bluestore label, you will lose the OSD's data.
- Recovery jobs (osd-wipe, bluestore-inspect, toolbox bring-up) live in
  `infrastructure/rook-recovery-jobs/` and are intentionally not part of the standard reconcile
  — they are manual apply only.

---

### External-Secrets / cross-cluster-eso (`infrastructure/external-secrets-config/` + `infrastructure/cross-cluster-eso/`)

**Purpose.** Two distinct `ClusterSecretStore` paths:

1. **Default CSS** (`infrastructure/external-secrets-config/`) — points at AWS Secrets Manager
   in account `700736442855` (USX-Dev) via IRSA. This is what 95% of `ExternalSecret` objects
   in the cluster target. Every secret the on-prem cluster owns lives in SM under
   `op-usxpress-dev/<name>`.

2. **Cross-cluster ESO** (`infrastructure/cross-cluster-eso/`) — a second CSS pointing at a
   cloud EKS cluster's API server, used when the secret's source of truth is a cloud-side
   `Secret` provisioned by cloud Terraform (e.g. ArgoCD-managed app config). Only secrets the
   cloud TF writes **directly** should bridge through this path; anything the cloud TF
   ultimately reads from AWS SM should be re-pointed at the default CSS instead.

**Key wiring.**

```yaml
# infrastructure/cross-cluster-eso/kustomization.yaml (as referenced from iaac-talos-flux-cluster)
# Split into its OWN flux Kustomization with wait: false
# Rationale: the cross-cluster token is seeded by an Octopus runbook AFTER Flux comes up.
# wait: true would block forever during bootstrap (chicken-and-egg).
```

**IRSA dependencies.** Default CSS uses the `external-secrets` SA bound to the role
provisioned by `iaac-talos` `modules/irsa/external-secrets`. The cross-cluster CSS does **not**
use IRSA — it uses a kubeconfig-style token seeded into a Secret by the Octopus bootstrap
runbook.

**Verified state.** Default CSS resolving `op-usxpress-dev/*` secrets across `velero`,
`etcd-backup`, `cert-manager`, `external-dns`, and every app namespace. Cross-cluster CSS
healthy after Octopus seeds the token.

**Gotchas.**
- The cross-cluster CSS is a single-point-of-failure for any app that depends on it. POC-only
  pattern; production-grade workloads should migrate to a default-CSS-friendly source.
- Bootstrap order matters — the cross-cluster Kustomization carries `wait: false` precisely so
  that a missing cross-cluster token at first reconcile does not stall the rest of the
  platform.

---

### External-DNS (`infrastructure/external-dns/`)

**Purpose.** Sync `Service` and `Ingress` / `Gateway` hostnames into Route 53 hosted zones
(`*.usxpress.io` for the root zone, plus per-team subzones). On-prem external traffic flows in
through the istio ingress gateway's hostPort + DaemonSet; external-dns publishes the workers'
IPs as A records for the relevant FQDNs.

**Chart / source.** `external-dns` chart **v0.20.0**.

**Key values.**

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

**IRSA dependencies.** SA `external-dns/external-dns` assumes
`op-usxpress-dev-external-dns` (Route 53 hosted-zone trust scoped to the parent account).

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

### Istio + cert-manager + gateway-passthrough (`infrastructure/istio/` + `infrastructure/cert-manager/`)

**Purpose.** L7 ingress + service mesh + TLS termination. Phases 0/1/2 are complete on
`op-usxpress-dev`:

- **Phase 0**: cert-manager + Let's Encrypt wildcard `ClusterIssuer`. `*.usxpress.io` cert
  active and renewing.
- **Phase 1**: TCP / SNI listeners on the istio ingress gateway, hostPort-bound on the
  DaemonSet across all workers (no on-prem L4 LB; the L2 announcement is via worker
  hostNetwork).
- **Phase 2**: backend TLS via ghostunnel sidecar — apps that require mTLS to upstream get a
  ghostunnel sidecar injected; istio mesh handles the public-facing TLS.

**Key wiring.**

```yaml
# infrastructure/istio/meshconfig.yaml (excerpt)
spec:
  meshConfig:
    defaultConfig:
      proxyMetadata: {}
    exportTo:
      - "*"        # CRITICAL — empty / unset blocks cross-ns VS visibility, RCA jun02
```

**Per-app VirtualService pattern (RW-2 example).**

```yaml
# Two VS per RW-2 namespace, one for HTTPS dashboard, one for SQL passthrough on a TCP port
# - rw2-dashboard      → HTTPS, terminates at istio
# - rw2-sql-passthrough → TCP/SNI passthrough to the RW-2 frontend
```

**IRSA dependencies.** cert-manager carries the route53 IRSA role for DNS-01 challenges on
the LE wildcard issuer.

**Verified state.** Root-zone wildcard cert active; per-team certs issuing on demand; mesh
exportTo confirmed across namespaces; ambient HBONE working for app traffic (with the Bitnami
chart NP exception called out below).

**Gotchas.** Bitnami charts ship a `NetworkPolicy` that blocks the ambient HBONE port — either
disable the chart NP or extend it. See common gotchas.

---

### rook-recovery-jobs (`infrastructure/rook-recovery-jobs/`)

**Purpose.** Manual-apply templates for Ceph recovery operations. Intentionally **not part of
the standard reconcile** — Flux does not own these; an operator applies them with `kubectl`
when the situation calls for it.

**Contents.**

- `osd-wipe.yaml` — privileged Job that runs `dd if=/dev/zero` against a named device. Use
  ONLY when an OSD is being decommissioned and a fresh OSD will take its place. Destroys data
  by design.
- `bluestore-inspect.yaml` — read-only diagnostic Job that runs `ceph-bluestore-tool` against
  a mounted device. Safe to apply against any device; reads the bluestore label and superblock
  and dumps to stdout.
- `toolbox.yaml` — bring up a one-shot toolbox Pod when the always-on toolbox is unavailable
  (e.g. during a Ceph upgrade window).

**IRSA dependencies.** None — these are cluster-local privileged operations.

**Verified state.** Templates exist; `bluestore-inspect.yaml` exercised against
`op-usxpress-dev` OSDs during the [bluestore label = SOT](https://github.com/variant-inc/iaac-talos/blob/feature/op-usxpress-dev/deploy/docs/troubleshooting/bluestore-label-sot.md)
investigation.

**Gotchas.** `osd-wipe.yaml` is destructive. Confirm the device name **on the right node**
(`lsblk` from a `nsenter` debug pod) before applying. Misnaming will wipe a healthy OSD or,
worse, a Talos system disk.

---

## Recent additions — jun23 marathon

Nine PRs landed on `op-dev` during the 2026-06-23 marathon close-out. Listed in merge order;
each corresponds to a section above.

| PR  | Component        | Change                                                                                              |
|-----|------------------|-----------------------------------------------------------------------------------------------------|
| #54 | rook-ceph        | `CephCluster.spec.resources.mgr.limits.memory: 2Gi` (was default 512Mi; mgr was OOMKilling 135×/16h) |
| #55 | velero           | Override `kubectl.image.repository: bitnamilegacy/kubectl` tag `1.32` (Bitnami removed versioned tags) |
| #56 | prometheus       | `storageSpec.volumeClaimTemplate.spec.storageClassName: ceph-block` (was emptyDir; lost 4.9 GiB / restart) |
| #57 | rook-ceph        | Toolbox always-on `Deployment` (chart toggle) — required for ad-hoc `ceph` CLI                       |
| #58 | etcd-backup      | PSA-restricted `seccompProfile: RuntimeDefault` on pod spec (Job was retrying forever silently)      |
| #59 | velero           | Add `AWS_REGION=us-east-2` via `configuration.extraEnvVars` (Kopia STS call needs it)                |
| #60 | velero           | Remove `nodeAgent.extraEnvVars` duplicate — chart renders BOTH onto the node-agent DS; SSA dup-key rollback |
| #61 | etcd-backup     | Multi-container restructure: distroless `talosctl` initContainer + `aws-cli` main + shared emptyDir `/work` |
| #62 | etcd-backup     | Memory bump: initContainer 256Mi → 1Gi (tmpfs accounting was eating into the limit on a 287 MiB snapshot) |

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
| external-secrets (default)| `external-secrets/eso-sa`      | `op-usxpress-dev-external-secrets`        | `modules/irsa/external-secrets`|
| cert-manager (DNS-01)     | `cert-manager/cert-manager`    | `op-usxpress-dev-cert-manager`            | `modules/irsa/cert-manager`   |
| prometheus                | n/a — no AWS calls             | —                                         | —                             |
| rook-ceph                 | n/a — cluster-local            | —                                         | —                             |

The `cross-cluster-eso` CSS is **not IRSA** — it carries a kubeconfig-style bearer token
seeded by the Octopus bootstrap runbook.

**Bring-up order matters**: the IRSA role must exist in AWS before the SA reconciles, or the
first pod will fail STS AssumeRole. The `iaac-talos` Terraform run is therefore a hard
prerequisite for any `infrastructure/<component>/` Kustomization that uses IRSA. For new
clusters, run `terraform apply` in `iaac-talos` to completion **before** the matching branch
in this repo is created.

---

## PSA awareness

All component namespaces in this repo enforce `PodSecurity: restricted` baseline-of-baselines.
Any pod spec landing in this repo must therefore:

- Set `securityContext.runAsNonRoot: true`.
- Set `securityContext.seccompProfile.type: RuntimeDefault` at the pod (and ideally container)
  level. **A missing seccompProfile under PSA-restricted causes a `Job` to retry forever
  silently** — the controller never marks the Job failed because the admission failure is
  per-Pod, and a new Pod is created on each retry. The `etcd-backup` CronJob fell into this
  trap before PR #58.
- Drop all capabilities (`securityContext.capabilities.drop: [ALL]`).
- Set `allowPrivilegeEscalation: false`.
- Set `runAsUser` and `runAsGroup` to non-zero IDs.

The one exception is `infrastructure/rook-recovery-jobs/osd-wipe.yaml`, which is privileged by
design and runs in `rook-ceph` (privileged namespace label). It is manual-apply only; Flux does
not own it.

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
4. **Cross-cluster ESO seed.** The Octopus bootstrap runbook seeds the cross-cluster token
   AFTER Flux is up. Skip cross-cluster ESO entirely if the new cluster does not need
   cloud-side secrets.
5. **Add Flux pointers.** In `iaac-talos-flux-cluster`, add a per-cluster
   `Kustomization`/`GitRepository` pair referencing the new branch.
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
  Consumes the `external-secrets-config` default CSS and the `ceph-block` SC defined here.

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

External blockers tracked outside this repo's PRs but adjacent to the marathon:

- **INFRA-1545 (Tim)** — RW-2 SQL pipeline final wiring.
- **INFRA-1535 / 1543 (Octopus admin)** — Octopus space + role wiring for OnPremise.
- **TF state cross-region (cloud-ops)** — moving `iaac-talos` Terraform state replication.

---

_Owner: Cloud Platform Team, Knight-Swift._
_Branch source-of-truth: `op-dev` for `op-usxpress-dev`._
_Questions: ping the Cloud Platform Team Slack channel; for on-prem outages page via
PagerDuty + Freshservice ticket._

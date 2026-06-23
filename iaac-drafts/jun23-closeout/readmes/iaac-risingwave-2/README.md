# iaac-risingwave-2 — Team-owned RisingWave (rw-2) IaC for op-usxpress-dev

Infrastructure-as-code for the Cloud Platform team's own RisingWave instance,
`rw-2`, running in namespace `risingwave-2` on the `op-usxpress-dev` on-prem
Talos cluster.

This repo is **not** the production RisingWave deployment. Tim Preble owns the
prod instance in namespace `risingwave`; that stack is sourced from
[`variant-inc/iaac-risingwave-onprem`](https://github.com/variant-inc/iaac-risingwave-onprem)
and is reconciled by Flux on its own cadence. `rw-2` exists alongside that
instance and is fully isolated by namespace.

---

## Purpose

`rw-2` is the Cloud Platform team's RisingWave for **pattern proving and
operational validation** on `op-usxpress-dev`. It is the instance we break,
upgrade first, attach new sidecars to, migrate storage on, and use to validate
operator-chart changes before any of those changes touch Tim's production
namespace. It carries no production data and no production traffic. Internal
team apps (and Idris's onboarding work) point at `rw-2` for SQL pipeline
experimentation; everything in production-critical paths points at Tim's
`risingwave` instance.

If you need a RisingWave for an experiment, a CI fixture target, a dashboard
demo, or a chart-upgrade rehearsal — use `rw-2`. If you have a production
streaming workload — coordinate with Tim and use `risingwave`.

---

## Repo layout

```
.
├── README.md                           # this file
├── flux/                               # Flux Kustomization entry points
│   └── op-usxpress-dev/
│       ├── kustomization.yaml          # top-level overlay for op-usxpress-dev
│       └── ks.yaml                     # Flux Kustomization CR (path -> ./apps)
├── apps/
│   └── risingwave-2/
│       ├── kustomization.yaml          # resource list
│       ├── namespace.yaml              # risingwave-2 namespace + PSA labels
│       ├── operator/
│       │   ├── helmrelease.yaml        # risingwave-operator HelmRelease
│       │   ├── helmrepository.yaml     # risingwavelabs OCI/HTTPS repo
│       │   └── clusterrole-supplemental.yaml   # see "operator chart gap"
│       ├── risingwave-cr/
│       │   └── risingwave.yaml         # RisingWave CR (meta/compute/frontend/compactor)
│       ├── postgres/
│       │   └── helmrelease.yaml        # bitnami/postgresql for RW metadata
│       └── prometheus/
│           └── helmrelease.yaml        # rw-2-scoped Prometheus bundle
└── runner/                             # ARC runner Kustomization (scope TBD)
    └── kustomization.yaml
```

> Note: the ARC runner that services rw-2 CI may live here or upstream in
> `iaac-talos-flux-platform`. Confirm before editing — the runner placement
> ticket has not been closed out.

---

## Stack components

### risingwave-operator

Deployed via the upstream `risingwave-operator` Helm chart published by
RisingWave Labs. The operator watches `RisingWave` CRD instances cluster-wide
and reconciles them into the per-component StatefulSets / Deployments /
Services that make up a working RisingWave.

The chart ships a namespace-scoped `Role`/`RoleBinding` only. The operator
actually needs cluster-scope `list`/`watch` on several core and apps resources
in order to reconcile across instances. See the
[supplemental ClusterRole](#risingwave-operator-chart-gap-supplemental-clusterrole)
section for the exact set we add and why.

### RisingWave CR

A single `RisingWave` custom resource named `risingwave` lives in the
`risingwave-2` namespace and defines all four component groups:

- `meta` — coordination/metadata, backed by external Postgres (see below)
- `compute` — stream/batch execution
- `frontend` — SQL endpoint (consumed by `rw2-sql-passthrough` VirtualService)
- `compactor` — state compaction

The CR is intentionally vanilla; sizing and resource overrides are encoded in
`apps/risingwave-2/risingwave-cr/risingwave.yaml`.

### Bundled Prometheus

A small Prometheus deployment scoped to `rw-2` lives in `risingwave-2` and
scrapes the operator and RisingWave component metrics. It is **not** the
cluster-wide Prometheus — the cluster's monitoring stack lives in the
`monitoring` namespace and is sourced from `iaac-talos-flux-platform`.

`rw-2` Prometheus is a thin convenience for inspecting `rw-2`'s own state
during chart upgrades and storage migrations without correlating against the
broader cluster Prometheus.

### Postgres

`bitnami/postgresql` Helm chart, single primary, providing metadata storage
for the RisingWave `meta` component. Currently sized small; PVC is the open
migration item described in [INFRA-1555](#tickets).

### Supplemental ClusterRole

`clusterrole-supplemental.yaml` patches the chart's RBAC gap. Required for the
operator to come up healthy. See its own section below.

---

## Branch model

- **`main`** is the single source of truth.
- Flux reconciles from `main` directly. There is **no** `flux-cluster` repo
  mapping for this stack — `iaac-risingwave-2` is itself the Flux source.
  (Tim's prod instance follows the same model out of
  `iaac-risingwave-onprem:main`.)
- Changes go through normal PR review against `main`. On merge, Flux picks
  them up on its next reconcile cycle (default 1m for the `rw-2` Kustomization).
- Do not push directly to `main`. Do not force-push.
- Branches are short-lived: branch, PR, merge, delete.

---

## Cluster targeting

Currently `op-usxpress-dev` only. The Flux Kustomization is wired at:

```
flux/op-usxpress-dev/ks.yaml
```

When we extend to a second cluster (QA, prod, or a parallel dev), the
expected pattern is one new directory under `flux/<cluster-name>/` with its
own Kustomization CR pointing at either the same `./apps/risingwave-2`
overlay or a cluster-specific overlay. The per-cluster supplemental
ClusterRole + ClusterRoleBinding must be applied each time — see
[Per-cluster bring-up](#per-cluster-bring-up).

---

## Recent additions — jun23 marathon

Three PRs landed during the 2026-06-23 marathon (umbrella INFRA-1544). All
three close out chart gaps or storage shortcuts that were blocking `rw-2`
from being treated as a real on-prem stack.

### PR #15 — operator supplemental ClusterRole (initial set)

INFRA-1550, first pass. The `risingwave-operator` chart ships only a `Role`
in the install namespace. The operator pod CrashLooped on startup with
errors of the form:

```
E0623 ... reflector.go: cannot list resource "configmaps" in API group ""
at the cluster scope
```

Added `clusterrole-supplemental.yaml` granting cluster-scope `get/list/watch`
on `configmaps` and `pods`, plus a matching `ClusterRoleBinding` pointing at
the operator ServiceAccount in `risingwave-2`. Operator came up clean.

### PR #16 — operator supplemental ClusterRole (extended set)

INFRA-1550, second pass. After the operator started, reconcile errors
surfaced for the remaining resources the operator manages cluster-wide.
Extended the supplemental ClusterRole to cover `statefulsets`, `deployments`,
`services`, `secrets`, `jobs`, and `customresourcedefinitions`.

Cumulative resource set is now **9 resources** across core, apps, batch, and
apiextensions API groups. Full block reproduced in the
[supplemental ClusterRole section](#risingwave-operator-chart-gap-supplemental-clusterrole)
below.

### PR #17 — rw-2 Prometheus PV on ceph-block

INFRA-1549. The bundled `rw-2` Prometheus was running on `emptyDir`, which
meant metrics history was lost every pod restart — including every chart
upgrade and every Talos node drain. Migrated `prometheus.server.persistentVolume`
to a 10Gi `ceph-block` PVC.

`ceph-block` is the Rook-Ceph–backed StorageClass on `op-usxpress-dev`
(~350 GiB available pool). This is `rw-2`'s first persistent dependency on
ceph-block. Postgres is the next one (deferred — see INFRA-1555).

---

## risingwave-operator chart gap: supplemental ClusterRole

**Why this exists.** The upstream chart packages RBAC at namespace scope
only. The operator's reconcile loop needs cluster-scope `list`/`watch` on the
resources it owns so it can reflect them into its informer cache. Without
the supplemental ClusterRole the operator either CrashLoops on startup or
silently fails to reconcile newly-created RisingWave instances.

**Where it lives.** `apps/risingwave-2/operator/clusterrole-supplemental.yaml`.
Wired into the operator overlay's `kustomization.yaml` resource list.

**Current set — 9 resources cumulative across PRs #15 and #16:**

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: risingwave-operator-supplemental
  labels:
    app.kubernetes.io/name: risingwave-operator
    app.kubernetes.io/part-of: risingwave-2
rules:
  - apiGroups: [""]
    resources:
      - configmaps
      - pods
      - services
      - secrets
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources:
      - statefulsets
      - deployments
    verbs: ["get", "list", "watch"]
  - apiGroups: ["batch"]
    resources:
      - jobs
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apiextensions.k8s.io"]
    resources:
      - customresourcedefinitions
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: risingwave-operator-supplemental
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: risingwave-operator-supplemental
subjects:
  - kind: ServiceAccount
    name: risingwave-operator
    namespace: risingwave-2
```

**Maintenance rule.** If `risingwave-operator` is upgraded and the operator
starts logging `cannot list <resource> at the cluster scope` (or its reconcile
silently no-ops on a resource it should own), extend this ClusterRole; do
**not** patch the chart's namespaced Role. Keep the supplemental file as the
single source for the gap; that keeps the chart drop-in replaceable on the
next upstream release.

**Per-install rule.** This supplemental ClusterRole + binding is required
**per cluster, per install namespace**. The binding's `subjects[].namespace`
identifies the operator SA, so a QA clone of `rw-2` (or any second install)
needs its own copy with the matching `namespace:` value.

---

## Storage: ceph-block migration

`op-usxpress-dev` exposes `ceph-block` as the production StorageClass,
Rook-Ceph backed, with ~350 GiB available in the pool. All persistent state
for `rw-2` is migrating onto it.

### Prometheus — done (PR #17, INFRA-1549)

`rw-2`'s bundled Prometheus PV now lives on `ceph-block`, 10Gi, in the
HelmRelease values block:

```yaml
prometheus:
  server:
    persistentVolume:
      enabled: true
      storageClass: ceph-block
      size: 10Gi
      accessModes:
        - ReadWriteOnce
```

This was `emptyDir` previously; metrics history now survives pod restarts,
node drains, and chart upgrades.

### Postgres — deferred (INFRA-1555)

`rw-2`'s metadata Postgres still runs on `local-path`, pinned by node
affinity to `talos-wk-op-dev-6`. That makes the node un-drainable without
data loss and is the last `local-path` PV in the `rw-2` stack.

Target state — Bitnami values fragment:

```yaml
primary:
  persistence:
    enabled: true
    storageClass: ceph-block
    size: 10Gi
    accessModes:
      - ReadWriteOnce
```

**Why deferred.** The migration is destructive — the existing PVC is
StorageClass `local-path` and cannot be retyped in place. The procedure is:

1. Velero pre-backup of the `risingwave-2` namespace as a safety net.
2. Quiesce the RisingWave CR (scale meta to 0).
3. `pg_dumpall` from the running Postgres to a tarball on operator host.
4. Delete the StatefulSet + PVC.
5. Re-apply the HelmRelease with `storageClass: ceph-block`.
6. `psql` restore from the tarball.
7. Scale meta back up; verify operator reconciliation.

Estimated window ~30 min, all within `risingwave-2` ns. Even though `rw-2`
is the team's instance, this work is coordinated with Tim before scheduling
— the operator pod is shared (single operator deployment watches both CRs
cluster-wide via the supplemental ClusterRole), so any operator disruption
during the migration has the potential to affect `risingwave` reconcile
even though no Postgres state is shared. Standing rule: any disruptive RW
change goes through Tim.

---

## Access

- **Platform team (cluster-admin).** Cluster-admin tokens are issued out of
  the standard on-prem split-provisioning flow (see
  `iaac-talos/deploy/docs/onprem_cluster_access_runbook.md` in the enterprise
  repo). Doke + Idris + on-call platform engineer have cluster-admin and can
  touch every namespace.
- **App teams (namespace-scoped).** Namespace-scoped tokens for `risingwave-2`
  are minted on request and bound to a `Role` in the namespace. They cannot
  cross into `risingwave` (Tim's ns) or any other namespace. Token issuance
  is tracked in the cluster access runbook.
- **Tim's `risingwave` ns is off-limits** from any `rw-2`-scoped token by
  construction. The supplemental ClusterRole grants only `get/list/watch`
  cluster-wide to the operator SA; it grants no cross-namespace write.

---

## Relationship to Tim's `risingwave` instance (iaac-risingwave-onprem)

| Aspect              | `rw-2` (this repo)            | `risingwave` (Tim's prod)        |
|---------------------|-------------------------------|----------------------------------|
| Namespace           | `risingwave-2`                | `risingwave`                     |
| Repo                | `variant-inc/iaac-risingwave-2` | `variant-inc/iaac-risingwave-onprem` |
| Flux source         | this repo `main`              | that repo `main`                 |
| Owner               | Cloud Platform team           | Tim Preble                       |
| Traffic class       | validation / experiments      | production                       |
| Storage SC          | ceph-block (Postgres pending) | per that repo                    |
| Operator            | shared cluster-wide operator (this repo's HelmRelease) | shared cluster-wide operator     |

The operator is **one deployment, cluster-wide**, installed and owned by this
repo. The CRs are per-namespace. That means an operator regression we ship
here can affect Tim's CR even though no data, config, or RBAC is shared.
Treat operator upgrades and supplemental ClusterRole changes as if they are
production changes regardless of which CR you are validating against.

**Hard rule.** Do not edit anything in `risingwave` ns from this repo's
context. Do not stand up `RisingWave` CRs in `risingwave` ns from here. Do
not point `rw-2` Prometheus at `risingwave` ns metrics endpoints without
Tim's sign-off.

---

## Per-cluster bring-up

When extending `rw-2` to a second cluster (QA being the likely first
candidate), the bring-up checklist is:

1. **Decide on namespace.** Either keep `risingwave-2` and rely on the
   cluster boundary, or rename to e.g. `risingwave-2-qa` if the QA cluster
   already has a `risingwave-2` for some reason. The supplemental
   ClusterRoleBinding's `subjects[].namespace` must match whichever you
   choose.
2. **New Flux Kustomization.** Add `flux/<cluster-name>/` with its own
   `ks.yaml` pointing at either `./apps/risingwave-2` or a cluster-scoped
   overlay if values diverge.
3. **Supplemental ClusterRole + binding.** Required again on the new
   cluster — RBAC is cluster-scoped, not Flux-managed cross-cluster. Same
   9-resource set unless the operator chart version differs.
4. **StorageClass mapping.** `ceph-block` is the on-prem name; if QA is on
   a different storage backend, override `storageClass` in both the
   Prometheus and Postgres HelmRelease values blocks.
5. **VirtualServices.** `rw2-dashboard` and `rw2-sql-passthrough` live in
   `iaac-talos-flux-platform` (Istio section), not here. The QA equivalent
   needs equivalent entries added to that repo's per-cluster Istio overlay.
6. **Cluster-admin + namespace tokens.** Issue per the access runbook.

---

## Operational runbooks

Stack-specific operational procedures (incident response, OOM tuning, PV
recovery, operator chart upgrade rehearsal) are kept in the enterprise IaC
repo, not here:

```
variant-inc/iaac-talos
└── deploy/docs/troubleshooting/
    ├── risingwave-operator-crashloop.md
    ├── risingwave-meta-postgres-loss.md
    ├── ceph-block-pvc-migration.md
    └── ...
```

The on-prem troubleshooting catalog is surfaced via the
`/onprem-troubleshooting` skill and is the single source for runbooks that
span more than one stack.

---

## Tickets

| Jira       | Status      | Scope                                                                 |
|------------|-------------|-----------------------------------------------------------------------|
| INFRA-1544 | umbrella    | jun23 marathon — rw-2 hardening pass                                  |
| INFRA-1550 | done        | Operator supplemental ClusterRole (PRs #15 + #16, 9 resources)        |
| INFRA-1549 | done        | rw-2 Prometheus PV → ceph-block 10Gi (PR #17)                         |
| INFRA-1555 | open        | Postgres PV migration local-path → ceph-block; needs Tim coord        |

Open work feeds into INFRA-1555 first; nothing else is blocking on the
operator or Prometheus side as of this README being adopted.

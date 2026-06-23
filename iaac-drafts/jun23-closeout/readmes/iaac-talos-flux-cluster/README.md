# iaac-talos-flux-cluster — Flux CD Kustomization Layer for On-Prem Talos

Enterprise repo: `variant-inc/iaac-talos-flux-cluster`
Default branch: `master`
Owner: Knight-Swift Cloud Platform team

---

## Purpose

This repo is the **Flux CD Kustomization orchestration layer** for the on-prem Talos
clusters. It holds the per-cluster `flux-system/` bootstrap manifests and the
top-level `Kustomization` graph that points Flux at the actual resource manifests
in the paired repo `variant-inc/iaac-talos-flux-platform`. Nothing in this repo
contains application Helm values, CRDs, or workload manifests — those live in
`iaac-talos-flux-platform`. This repo decides **which** Kustomizations exist,
**in what order** they reconcile, **whether they are suspended**, and **which
branch of the platform repo** they track. Treat it as the wiring harness; the
platform repo is the appliance.

The pairing is deliberate. Operators changing reconciliation behavior
(suspend / un-suspend, dependsOn, prune, wait) touch only this repo. Operators
changing what gets deployed (chart version, Helm values, CRD bumps) touch only
the platform repo. Keeping the two layers split avoids mixing
"how Flux behaves" with "what the cluster runs," which has historically led to
PR reviews that conflate kstatus semantics with workload changes.

---

## Repo layout

```
.
├── README.md
└── clusters/
    └── bm-dev/                          # op-usxpress-dev (see naming section)
        ├── flux-system/
        │   ├── gotk-components.yaml      # flux bootstrap — Flux controllers
        │   ├── gotk-sync.yaml            # GitRepository + root Kustomization
        │   └── kustomization.yaml
        └── apps/
            ├── cilium/
            │   └── kustomization.yaml    # Kustomization → platform repo path
            ├── cert-manager/
            ├── external-secrets/
            ├── external-secrets-config/  # ClusterSecretStore only — wait: false
            ├── rook-ceph/
            ├── rook-ceph-cluster/
            ├── istio-base/
            ├── istio-istiod/
            ├── istio-gateway/
            ├── external-dns/
            ├── reloader/
            ├── kube-prometheus-stack/
            ├── velero/
            ├── etcd-backup/
            ├── risingwave-operator/
            ├── rw-2/
            └── kustomization.yaml        # apps-of-apps aggregator
```

Every directory under `clusters/<name>/apps/<app>/` contains exactly one
`kustomization.yaml` that declares a `kustomize.toolkit.fluxcd.io/v1`
Kustomization. That Kustomization's `spec.path` points at a directory in the
platform repo (e.g., `./infrastructure/velero`). The platform repo's path is
where the HelmRelease + supporting resources live.

---

## Naming conventions

| Identity                  | Where it appears                                          | Notes |
| ------------------------- | --------------------------------------------------------- | ----- |
| `op-usxpress-dev`         | Conversation, Octopus, Talos cluster name                 | The cluster's customer-facing name. |
| `bm-dev`                  | `clusters/bm-dev/` in this repo, GitRepository name       | Legacy directory name — predates `op-` prefix. Retained so the existing GitRepository and root Kustomization don't churn. |
| `talos-cp-op-dev-{1,2,3}` | Talos VM names, talosconfig                               | Node-level identity. Not used in Flux paths. |

**Rule for new clusters:** use the customer-facing cluster name as the
directory under `clusters/`. Do not propagate `bm-dev`. Example:

```
clusters/qa-dev/         # for op-usxpress-qa
clusters/op-usxpress-prod/
```

The legacy `bm-dev` directory stays as-is. Renaming it now would force a
GitRepository re-bootstrap and break Flux's inventory tracking for every
Kustomization on the live cluster. Cost > benefit.

---

## How Flux reads this repo

1. **Bootstrap** (one-time): `flux bootstrap git` is run against this repo,
   path `clusters/<name>`. It writes `flux-system/gotk-components.yaml` (the
   Flux controllers) and `flux-system/gotk-sync.yaml` (a `GitRepository` +
   root `Kustomization`).
2. **GitRepository** in `gotk-sync.yaml` polls this repo at
   `ref.branch: master`. It re-reads on the controller's interval (default
   1m) and pins to the latest commit on the branch.
3. **Root Kustomization** in `gotk-sync.yaml` reconciles
   `./clusters/<name>` — which kustomize-builds the `apps/kustomization.yaml`
   aggregator. That aggregator references every per-app
   `apps/<app>/kustomization.yaml`.
4. **Per-app Kustomization** then references the **platform repo** at a path
   like `./infrastructure/velero`. Flux's Kustomize controller pulls that
   path and applies whatever HelmRelease / Kustomize resources live there.

Concretely, `clusters/bm-dev/apps/velero/kustomization.yaml` looks like:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: velero
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 2m
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: iaac-talos-flux-platform
    namespace: flux-system
  path: ./infrastructure/velero
  prune: true
  wait: true
  dependsOn:
    - name: external-secrets-config
```

The `sourceRef` is a second `GitRepository` (defined under
`clusters/bm-dev/apps/` or `clusters/bm-dev/flux-system/`) that points at
`iaac-talos-flux-platform` on its op-dev branch. So this repo's job is
purely to declare:

- **what** Kustomizations exist on the cluster,
- **what platform path** each one points at,
- **what order** they reconcile in (`dependsOn`),
- **whether** they prune, wait, suspend.

---

## Recent additions — jun23 marathon

### PR #23 — Un-suspend Velero + etcd-backup

`clusters/bm-dev/apps/velero/kustomization.yaml` and
`clusters/bm-dev/apps/etcd-backup/kustomization.yaml` had `spec.suspend: true`
set during initial setup. Both were flipped to `false` via this repo (PR #23)
once IRSA + S3 + ClusterSecretStore wiring was confirmed end-to-end and a
restore drill succeeded.

Why git and not `flux resume kustomization velero -n flux-system`: the
`flux resume` CLI mutates the live object only. The next git reconcile would
re-apply `suspend: true` from `master` and the Kustomization would freeze
again. The binding rule is **all suspend state is IaC**. The only correct
way to un-suspend is to delete the line in git, or set it explicitly to
`false`, and let the root Kustomization propagate the change.

### Cross-reference: iaac-talos-flux-platform default branch flip

`iaac-talos-flux-platform` default branch changed from `prod` to `op-dev`
during the same marathon. This repo's GitRepository ref for the platform
repo must match. If you find an `apps/*/kustomization.yaml` or a
`flux-system` GitRepository definition still pointing at `prod`, update it
to `op-dev` and validate locally with:

```bash
flux build kustomization velero \
  --kustomization-file clusters/bm-dev/apps/velero/kustomization.yaml \
  --path . \
  --dry-run
```

---

## Kustomization patterns

### 7.1 Suspend / un-suspend via IaC (never live)

`spec.suspend: true` is the only field that should ever be set on a
Kustomization to pause reconciliation. **Never** use `kubectl patch` or
`flux suspend kustomization <name>` to suspend on the live cluster. Reasons:

- The live mutation is not in git. The next git reconcile of the root
  Kustomization will overwrite it.
- An operator coming behind you cannot tell from `git log` why the
  Kustomization is frozen.
- Restores from this repo (cluster rebuild) silently un-suspend things you
  meant to keep frozen.

Use `flux suspend` only as a temporary mitigation during an incident where
you cannot get a PR in. As soon as the immediate firefight is over, commit
the `suspend: true` to git and merge before walking away.

### 7.2 `wait: false` for CSS-only Kustomizations (chicken-and-egg break)

Some Kustomizations own nothing but a `ClusterSecretStore` (CSS) that
itself references a `Secret` seeded by Octopus or by another Kustomization.
On a cold-bootstrap cluster, the CSS will fail readiness (its source
secret doesn't exist yet) and **block every Kustomization that depends on
external-secrets-config**. The break-the-cycle pattern is:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: external-secrets-config
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: iaac-talos-flux-platform
  path: ./infrastructure/external-secrets-config
  prune: true
  wait: false             # <-- intentional. CSS readiness depends on
                          #     Octopus-seeded secret materializing.
  dependsOn:
    - name: external-secrets
```

With `wait: false`, Flux marks the Kustomization Ready as soon as the
manifests apply — it does **not** wait for the CSS to reach Ready. The
downstream `ExternalSecret`s will retry on their own controller-level
interval once the seed Secret lands. This is the jun22 cross-cluster-ESO
refactor pattern.

### 7.3 `dependsOn` ordering

`dependsOn` is the only knob this repo has for ordering reconciliation.
Use it sparingly — every dependency adds a serialization point that
slows bootstrap. Canonical chain:

```
cilium                    (CNI — must be Ready before any Pod schedules)
  └── cert-manager        (TLS root for everything else)
        └── external-secrets
              └── external-secrets-config  (wait: false; CSS only)
                    ├── velero
                    ├── etcd-backup
                    ├── rook-ceph
                    │     └── rook-ceph-cluster
                    ├── istio-base
                    │     └── istio-istiod
                    │           └── istio-gateway
                    ├── external-dns
                    ├── reloader
                    └── kube-prometheus-stack
                          └── rw-2
```

Practical rules:
- **CNI first.** Cilium has no `dependsOn`; everything else transitively
  depends on it via cert-manager.
- **CRD owners before consumers.** `rook-ceph` (operator + CRDs) must
  reach Ready before `rook-ceph-cluster` (CephCluster CR). Same for
  `istio-base` → `istio-istiod`.
- **No dependsOn on suspended Kustomizations.** A suspended dep blocks
  the dependant forever. If you're about to suspend, audit who depends
  on it first.

Example:

```yaml
spec:
  dependsOn:
    - name: external-secrets
    - name: external-secrets-config
```

### 7.4 `prune: true` vs `prune: false`

| Setting          | When to use                                                                 |
| ---------------- | --------------------------------------------------------------------------- |
| `prune: true`    | Default for app Kustomizations. Removing a resource from git removes it from the cluster on next reconcile. Required for clean app uninstall via PR. |
| `prune: false`   | Use for Kustomizations that own resources also touched by another controller (e.g., a CRD owned by both an operator chart and a separate CRD-only Kustomization). Also use for the `flux-system` bootstrap Kustomization itself — Flux must not prune its own controllers. |

**Inventory gotcha:** Flux tracks pruning via an inventory annotation on
the Kustomization object. If you switch a Kustomization from `prune: false`
to `prune: true` **and** simultaneously rename / delete a tracked resource,
Flux may not delete the orphan because it was never in the inventory. Fix:
flip prune in one commit, change resources in a follow-up commit.

---

## PSA awareness

Several namespaces on op-usxpress-dev run with Pod Security Admission set
to `enforce: restricted`. Examples: `velero`, `etcd-backup`, `monitoring`,
`external-secrets`. A manifest landing in the platform repo that targets a
restricted namespace **must** carry the full restricted pod-security
contract:

```yaml
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    fsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
        seccompProfile:
          type: RuntimeDefault
```

The most common omission is `seccompProfile.type: RuntimeDefault` at the
Pod level. Without it, PSA restricted rejects the Pod and a `Job` /
`CronJob` will retry forever **silently** — there is no event surfaced
unless you look at the namespace's `events` or the controller's
`status.conditions`. Symptom: a CronJob shows `lastScheduleTime` advancing
but no successful or failed Job ever materializes.

This is a platform-repo concern but listed here so reviewers of this repo
know to push back when a new Kustomization is proposed for a restricted
namespace without confirming the upstream manifests are PSA-clean.

---

## Flux kstatus terminal-failure gotcha

Flux uses `kstatus` to decide whether a reconciliation succeeded, failed,
or should be retried. **Some failures are classified as terminal** —
Ready=False with a reason that says, in effect, "this will not succeed on
retry without intervention." Examples:

- `BuildFailed` — kustomize build of the platform-repo path errored.
- `HealthCheckFailed` (when `wait: true` and a referenced resource hits
  a terminal state like Helm release `install-failed`).
- A HelmRelease whose CRD does not exist on the cluster yet.

**Flux will not retry these on its own.** The Kustomization is parked at
Ready=False and stays there even after you fix the underlying cause —
unless something triggers a reconcile. Earlier this year, a missing CRD
parked `external-secrets-config` at Ready=False. Once the CRD landed,
nothing kicked the Kustomization. Downstream Kustomizations (everything
with `dependsOn: external-secrets-config`) stayed blocked for 32 days
before the cascade was unwound.

**Recovery options, in preference order:**

1. **Commit a no-op change to git.** Bump an annotation on the
   Kustomization, or any small change in the referenced platform path.
   Next GitRepository poll re-reconciles. This is the IaC-correct path.
2. **Annotate to force reconcile** (operator escape hatch — leaves no git
   trace, use only when (1) is blocked):
   ```bash
   flux reconcile kustomization <name> -n flux-system --with-source
   ```
3. **Suspend then un-suspend via git** (heavyweight — two PRs). Only use
   if (1) doesn't dislodge the terminal status.

**Detection:** `flux get kustomizations -A` shows Ready=False with a
reason. Pipe it through a watch and alert on any Kustomization in
Ready=False for more than the configured `retryInterval * 3`. Without
that alert, terminal-failure Kustomizations rot invisibly.

---

## Per-cluster bring-up

When standing up a new on-prem Talos cluster (e.g., op-usxpress-qa):

1. **Copy the cluster directory:**
   ```bash
   cp -r clusters/bm-dev clusters/qa-dev
   ```
2. **Search-replace cluster-specific values** in the new directory:
   - `clusters/qa-dev/flux-system/gotk-sync.yaml` — update GitRepository
     name, branch (if the new cluster tracks a different platform-repo
     branch), and any cluster-name annotations.
   - `clusters/qa-dev/apps/<app>/kustomization.yaml` — update
     `sourceRef.name` if your branching convention pairs each cluster
     with a dedicated platform-repo branch.
3. **Decide platform-repo branch pairing.** The convention is one
   platform-repo branch per cluster (`op-dev`, `op-qa`, `op-prod`).
   Cluster directories in this repo point GitRepository at the matching
   branch. Cluster bring-up is therefore a two-commit operation: branch
   the platform repo first, then add the new cluster directory here.
4. **Push to a feature branch and open a PR.** Do **not** merge into
   `master` until the new cluster has been talos-bootstrapped and is
   reachable. The merge to `master` is what causes Flux on the new
   cluster (once bootstrapped) to start reconciling.
5. **Bootstrap Flux on the new cluster:**
   ```bash
   flux bootstrap git \
     --url=ssh://git@github.com/variant-inc/iaac-talos-flux-cluster \
     --branch=master \
     --path=clusters/qa-dev \
     --private-key-file=~/.ssh/flux-deploy-key
   ```
6. **Verify reconciliation:**
   ```bash
   flux get kustomizations -A
   flux get sources git -A
   ```

---

## Branch + default branch convention

| Repo                          | Default branch | Per-cluster branching                                         |
| ----------------------------- | -------------- | ------------------------------------------------------------- |
| `iaac-talos-flux-cluster`     | `master`       | **Single branch.** All clusters live in `clusters/<name>/` on `master`. |
| `iaac-talos-flux-platform`    | `op-dev`       | One branch per cluster (`op-dev`, future `op-qa`, `op-prod`). |
| `iaac-talos`                  | `master`       | Per-environment via Octopus variables, not branches.          |

This repo is a flat orchestration layer. We do not branch per-cluster
here because (a) every cluster's Kustomization graph is independent
under `clusters/<name>/`, and (b) Flux's GitRepository can't elegantly
follow a per-cluster branch in a single repo without a separate
GitRepository per cluster. Keeping `master` as the single branch
matches the bootstrap-flux convention and keeps cross-cluster diffs
visible in `git log`.

Platform-repo branching, by contrast, is per-cluster because that's
where workload chart versions and Helm values diverge between dev /
QA / prod.

---

## Operational runbooks

Day-2 runbooks live in the enterprise repo
`variant-inc/iaac-talos` under:

```
deploy/docs/troubleshooting/runbooks/
  flux-bootstrap-from-scratch.md
  flux-kstatus-terminal-recovery.md
  flux-suspend-via-iac.md
  flux-source-controller-cert-drift.md
```

Pointers — not duplicated here. If you make a structural change to this
repo that invalidates a runbook (e.g., reshape `flux-system/`), update
the runbook in the same PR train.

---

## Common gotchas

### Flux kstatus terminal-failure

See dedicated section above. Single most expensive Flux gotcha on this
platform. Worth re-reading before any change that adds a new
Kustomization or restructures `dependsOn`.

### Prune inventory gotcha

Flipping `prune: false` → `prune: true` while simultaneously renaming or
deleting a managed resource leaves orphans on the cluster because they
were never in the inventory. Always do prune-flip and resource-change in
separate commits.

### GitRepository commit pin behavior

A GitRepository tracks a branch by **commit SHA**, not by branch ref. If
you force-push the branch (rewriting history), the source-controller may
keep serving the old SHA until the next poll succeeds. Avoid force-push
on `master`. If you must rewrite (e.g., to scrub a secret), force a
source reconcile after:

```bash
flux reconcile source git flux-system -n flux-system
```

### `gotk-sync.yaml` is generated, not hand-edited

`flux-system/gotk-sync.yaml` and `flux-system/gotk-components.yaml` are
emitted by `flux bootstrap`. Hand-editing them is supported but discouraged
— next `flux bootstrap` (e.g., to upgrade the Flux version) will overwrite
your edits. Custom changes (e.g., adding a second GitRepository for the
platform repo) belong in a sibling file under `flux-system/`, included
via `flux-system/kustomization.yaml`.

### Kustomization `interval` vs `retryInterval`

`interval` is the success-path poll. `retryInterval` is the failure-path
retry. Setting `retryInterval` too short on a Kustomization with
`wait: true` and heavy resources (e.g., Rook CephCluster) wastes
controller CPU and can mask real failures by retrying before the
underlying issue is diagnosable. Defaults: `interval: 10m`,
`retryInterval: 2m`.

### Cilium must reach Ready before anything else

This is true even though `dependsOn` does not list cilium as a dependency
of every Kustomization (transitively, everything depends on cert-manager,
which depends on cilium). If you ever consider removing cert-manager from
the chain (e.g., for a cluster that uses a different cert flow), add an
explicit `dependsOn: cilium` to every leaf Kustomization or you will
get a Pod-scheduling race.

---

## Related repos

| Repo                              | Role                                                       |
| --------------------------------- | ---------------------------------------------------------- |
| `variant-inc/iaac-talos`          | Terraform for Talos VMs, CP/worker config, S3 tfstate.     |
| `variant-inc/iaac-talos-flux-platform` | HelmReleases + Kustomize resource manifests. Paired with this repo. |
| `variant-inc/iaac-risingwave-2`   | rw-2 application manifests (referenced by `apps/rw-2/`).   |
| `variant-inc/iaac-risingwave-onprem` | Tim Preble's RisingWave instance (separate namespace).  |
| `variant-inc/iaac-octopus-onprem` | Octopus runbooks that drive Talos + Flux bootstrap.        |
| `variant-inc/iaac-monitoring`     | Source for cloud-side monitoring patterns mirrored here.   |

---

## Tickets

| Ticket      | Scope                                                          |
| ----------- | -------------------------------------------------------------- |
| INFRA-1544  | jun23 marathon umbrella — Velero / etcd-backup un-suspend, default branch flip, observability shipping. |
| INFRA-1542  | Flux bootstrap automation follow-up — Octopus runbook to do per-cluster bring-up without manual `flux bootstrap git`. |
| INFRA-1494  | Phase 1 TCP/SNI listeners (closed; referenced by `apps/istio-gateway/`). |
| INFRA-1495  | Phase 2 backend TLS (closed; referenced by `apps/istio-gateway/`). |
| INFRA-1527  | platform-app-expose chart (consumed downstream by apps Kustomizations). |

For day-of-incident context, see `wip/` in the team workspace —
specifically `wip/jun23-marathon/STATE.md` and the on-prem
troubleshooting catalog under `wip/onprem-troubleshooting/`.

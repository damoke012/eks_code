# 07 — `iaac-risingwave-onprem`

Read 2026-09-17 · `main` `62e56b3`, tag `v0.5.6`

RisingWave: the operator, the `RisingWave` CR, Postgres, Prometheus, Grafana, the console, the
bootstrap Jobs and the Terraform that backs them. **This is the repo that cannot follow the
promotion rule**, and this section exists as much to establish that as to describe it.

---

## 1. Two halves, two very different gates

| Half | Path | Trigger | Gate |
|---|---|---|---|
| Terraform | `deploy/` | `.github/workflows/octo.yaml` on **every branch** → Octopus project `iaac-risingwave-onprem`, space DevOps | **`TfApply`** — per environment, in Octopus |
| Manifests | `manifests/<cluster>/` | Flux, pulling `branch: main` every **5 minutes** | **none** |

```powershell
# deploy/deploy.ps1
ce terraform plan -out=tfplan -input=false -no-color
if ($TfApply -eq "true") { ce terraform apply tfplan }
else { Write-Host "[STEP] TfApply != true — plan only, no apply." }
```

The Terraform half is fine. It inherits the same per-environment control as `iaac-talos`.

## 2. The manifests half has no promotion step at all

Three environments share one branch:

```
manifests/op-usxpress-dev/    34 files
manifests/op-usxpress-qa/     24 files
manifests/op-usxpress-prod/   24 files
```

And each cluster's Flux wiring — which lives in **`iaac-talos-flux-cluster`**, not here — points
every one of them at the same ref:

```yaml
# clusters/op-usxpress-qa/flux-system/infra.yaml
kind: GitRepository
metadata:
  name: iaac-risingwave-onprem
spec:
  interval: 5m0s
  ref:
    branch: main                                    # <-- every cluster, same branch
  url: https://github.com/variant-inc/iaac-risingwave-onprem.git
---
kind: Kustomization
metadata:
  name: risingwave-onprem
spec:
  path: ./manifests/op-usxpress-qa                  # only the PATH differs per cluster
  prune: false
---
kind: Kustomization
metadata:
  name: risingwave-operator
spec:
  path: ./manifests/op-usxpress-qa/operator
  prune: true
```

Identical shape on dev (`path: ./manifests/op-usxpress-dev`) and on **prod**, verified
2026-09-17:

```yaml
# clusters/op-usxpress-prod/flux-system/infra.yaml
  name: iaac-risingwave-onprem
  namespace: flux-system
spec:
  interval: 5m0s
  ref:
    branch: main
  url: https://github.com/variant-inc/iaac-risingwave-onprem.git
```

Prod's Kustomization additionally sets `wait: true` and `timeout: 10m0s`, and carries its own
`postRenderer`. **All three clusters track the same branch.**

**Prod joined this pipeline on 2026-09-17**, in `33efcd9` — *INFRA-1674: wire RisingWave into
op-usxpress-prod (#38)*. Before that commit prod had no RisingWave wiring at all, deliberately: the
comment it replaced recorded that wiring a path which did not yet exist in
`iaac-risingwave-onprem` had already cost a 17-day "path not found" failure. So prod went from
*not deployed* to *deployed from an unpinned branch* in one step, without an intermediate state
where it tracked a fixed version.

**So a merge to `main` that touches `manifests/op-usxpress-prod/` reaches production within five
minutes.** There is no release, no tag, no approval, no environment branch. The only pre-merge
check is `manifest-lint.yaml`, which runs on `pull_request` and does a `kustomize build` — it
proves the YAML renders, not that it can apply to the objects that already exist. Today's incident
is exactly the gap: `kustomize build` succeeded and the **server-side apply** failed.

> `prune: false` on the RisingWave Kustomization is deliberate: *"protect-RW insurance so Flux can
> NEVER delete in Tim's ns."* It protects against deletion. It does nothing about a bad update.

**This contradicts standing rule 10** ([[promotion-order-qa2-dev-qa-prod]]), and not as an
oversight — the repo has no mechanism that *could* express QA2 → dev → QA → prod.

### The two ways out

| Option | Change | Cost |
|---|---|---|
| **Pin each cluster to a tag** | `ref: { tag: v0.5.6 }` instead of `branch: main`; promote by moving the tag per environment | one line per cluster, in the cluster repo; the repo already tags (`v0.5.6`, `v0.5`, `v0`) |
| **Branch per environment** | `main` → `op-dev`/`op-qa`/`op-prod`, like `iaac-talos-flux-platform` | matches an existing house pattern, but every fix needs three merges |

The tag route is smaller, uses machinery that already exists, and gives dev a `branch: main`
"always latest" while QA and prod sit on an explicit version. **Recommended.**

## 3. The manifest you read is not the manifest that lands

Each cluster's Kustomization carries a `postRenderer` — again in the **cluster** repo — that
patches the `RisingWave` CR after it is rendered:

```yaml
postRenderers:
  - kustomize:
      patches:
        - target: { kind: RisingWave, name: risingwave }
          patch: |-
            - path: /spec/components/compute/nodeGroups/0/template/spec/resources/requests/cpu
            - path: /spec/components/compute/nodeGroups/0/template/spec/resources/requests/memory
            - path: /spec/components/compute/nodeGroups/0/template/spec/resources/limits/cpu
            - path: /spec/components/compute/nodeGroups/0/template/spec/resources/limits/memory
            - path: /spec/components/meta/nodeGroups/0/template/spec/env/-
            - path: /spec/components/frontend/nodeGroups/0/template/spec/env
            - path: /spec/stateStore
        - target: { kind: HelmRelease, name: risingwave-operator }
          patch: |-
            - path: /spec/chart/spec/version
```

Two consequences, both load-bearing:

1. **RisingWave's machine sizes are not in this repo.** CPU and memory requests and limits for the
   compute node group are set per cluster, in `iaac-talos-flux-cluster`. Reading
   `manifests/op-usxpress-qa/risingwave-cr.yaml` tells you what dev asked for, not what QA runs.
   The same is true of `stateStore` (the object store) and the operator's **chart version**.
2. **These are index patches** — `nodeGroups/0`, `env/-`. If the base list ever changes length or
   order they retarget silently ([[kustomize-index-patches-are-fragile]]). This is that trap, live,
   on the CR that owns the database.

**Review rule:** a PR to this repo cannot be assessed from this repo. Render the cluster's
overlay, or read the matching `postRenderer` block, before believing any value in it.

## 4. What is in `manifests/<cluster>/`

Dev's 34 files, of which QA and prod have 24. The extra ten are dashboards and bootstrap Jobs.

| Group | Files |
|---|---|
| Operator | `operator-helmrelease.yaml`, `operator-rbac-supplemental.yaml` |
| RisingWave | `risingwave-cr.yaml`, `rw-license-key.yaml`, `rw-secret-private-key.yaml` |
| Console + SSO | `risingwave-console.yaml`, `console-ext.yaml`, `dex-entra-externalsecret.yaml` |
| Postgres | `postgres-helmrelease.yaml`, `pg-postgresql.yaml`, `pg-externalsecret.yaml`, `pg-postgresql-ext.yaml` |
| Observability | `prometheus-helmrelease.yaml`, `grafana-helmrelease.yaml`, `grafana.yaml`, `grafana-dashboards-pvc.yaml`, `dashboard-ext.yaml` |
| TLS / tunnels | `ghostunnel-rw-frontend.yaml`, `ghostunnel-rw-postgres.yaml`, `rw-sql-frontend-cert.yaml` |
| Bootstrap Jobs | `rw-root-bootstrap-job.yaml`, `rw-service-accounts-bootstrap-job.yaml`, `rw-service-accounts-externalsecret.yaml` |
| Dev only | `risingwave-*-dashboard.json` + `.part-NN` splits |

**Dev is not a scale model of QA.** Ten files exist only there, so "prove it on dev first" is
partial for anything touching dashboards or bootstrap.

## 5. Machine sizes

- **RisingWave components:** per cluster, in the `postRenderer` in `iaac-talos-flux-cluster`. Not
  here. See §3.
- **Everything else** (Postgres, Prometheus, Grafana): in each environment's HelmRelease values in
  this repo.
- **Operator chart version:** per cluster, in the `postRenderer`. Two environments can run
  different operator versions from the same `main`.

## 6. Also worth knowing

- **`risingwave-2` is a different repo.** `bm-dev` wires a second GitRepository,
  `iaac-risingwave-2` (`branch: main`), to `./manifests/op-usxpress-dev` with `prune: true`. Dev
  only, never promoted.
- **QA splits the operator into its own Kustomization** (`prune: true`) while the RisingWave
  Kustomization stays `prune: false`. Dev does not. That split is why the 2026-09-17 freeze had a
  two-Kustomization blast radius.
- 16 branches on the repo, several long-lived (`feat/risingwave`, `restore/flux-repo`,
  `fix/qa-operator-split`). Worth a sweep for ones that were merged by cherry-pick.

## 7. What is NOT automated

| # | Gap | Consequence |
|---|---|---|
| 1 | **No gate between merge and prod.** One `main`, five-minute interval — **prod included since 2026-09-17**. | Rule 10 cannot be followed. A prod-affecting change is one merge away, and the only check proves rendering, not applying. |
| 2 | **`manifest-lint` cannot catch an apply failure.** `kustomize build` succeeds on a manifest that server-side apply will reject. | The exact 2026-09-17 failure mode ([[server-side-apply-keeps-dropped-fields]]). A `--server-side --dry-run=server` check against a live cluster would catch it; a render never will. |
| 3 | **No alert on a stuck Kustomization.** | The freeze ran ~4h unnoticed. `scripts/flux-kustomization-health.sh` detects it; alert C6 is blocked on Alertmanager. |
| 4 | **Not read:** `deploy/terraform/{main,secrets,outputs,variables}.tf`, `deploy/README.md`, `console-ui-enablement-runbook.md`. | §1 and §5 are partial on the Terraform side. |

---

## Proven

- **All three clusters** — dev, QA and prod — track `branch: main` of `iaac-risingwave-onprem` at
  a 5-minute interval, each with a per-cluster `path`. Read from `iaac-talos-flux-cluster` on
  `master`, 2026-09-17.
- The Terraform half retains a `TfApply` gate; the manifests half has none.
- `manifest-lint.yaml` runs only on `pull_request`.
- RisingWave resource requests/limits, `stateStore`, and the operator chart version are set by a
  `postRenderer` in the cluster repo, not by this repo.
- All three environment directories exist — dev 34 files, QA 24, prod 24.

## Tested and killed

- *"Prod RisingWave is blocked on manifests not existing."* **Out of date** —
  `manifests/op-usxpress-prod/` is present with 24 files.
- *"A PR to this repo can be reviewed from this repo."* It cannot; the values that matter are
  patched in elsewhere.

## Traps

1. **Merging to `main` deploys to production in five minutes.**
2. **A green `manifest-lint` does not mean the manifest can apply** — it renders, it does not
   apply to the object that already exists.
3. **The CR in git is not the CR in the cluster.** Sizes, state store and operator version come
   from the cluster repo's `postRenderer`.
4. **Those patches are index-based** and retarget silently if a list changes.
5. **`prune: false` protects against deletion, not against a bad update.**
6. **Dev has ten files QA and prod do not**, so dev is not a complete rehearsal.

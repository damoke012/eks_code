# Repo 2 — `variant-inc/iaac-talos-flux-cluster`

**Repo:** <https://github.com/variant-inc/iaac-talos-flux-cluster>
**Read at:** `master` @ [`33efcd9`](https://github.com/variant-inc/iaac-talos-flux-cluster/tree/33efcd9), 2026-09-17.

**What it does:** holds the Flux objects that tell each cluster where to get everything else.
It contains **no platform content** — only the wiring. One directory per cluster, single
`master` branch, no per-environment branches.

```bash
gh repo clone variant-inc/iaac-talos-flux-cluster
```

---

## 1. Layout

```
clusters/
├── bm-dev/            ← on-prem DEV. Note the name: NOT op-usxpress-dev
├── op-usxpress-qa/
├── op-usxpress-prod/
├── dpl/               ← devops playground
├── dpl2/              ← INCOMPLETE: no gotk-components, gotk-sync or kustomization
└── dpl2.bak/          ← a backup directory, committed
```

Each cluster directory holds exactly five files under `flux-system/`:

| File | What it is | Who writes it |
|---|---|---|
| `gotk-components.yaml` | the Flux controllers themselves | `flux bootstrap` |
| `gotk-sync.yaml` | `GitRepository` **flux-system** + its `Kustomization` | `flux bootstrap` (pre-writable) |
| `infra-source.yaml` | `GitRepository` **infra** + **gateway-api-upstream** | a human |
| `infra.yaml` | every `infrastructure/*` Kustomization | a human |
| `kustomization.yaml` | enumerates the four above | a human |

`kustomization.yaml` **enumerates** — a file dropped into the directory does nothing unless
listed ([[kustomization-enumerates-resources]]).

---

## 2. The two Git sources, and why the distinction matters

This is the thing to get right, and it is easy to get wrong.

```yaml
# gotk-sync.yaml — the CLUSTER repo, on master, scoped to THIS cluster's directory
spec:
  ref: { branch: master }
  url: https://github.com/variant-inc/iaac-talos-flux-cluster.git
---
spec:
  path: ./clusters/op-usxpress-qa
```

```yaml
# infra-source.yaml — the PLATFORM repo, on a PER-ENVIRONMENT branch
spec:
  interval: 5m0s
  url: https://github.com/variant-inc/iaac-talos-flux-platform
  ref: { branch: op-qa }
  secretRef: { name: flux-system }
```

**The cluster repo is single-branch; the platform repo is branch-per-environment.** A new
cluster therefore needs **both**: a new directory on `master` here, *and* a new branch in the
platform repo. Getting this wrong costs a session — `git fetch origin op-qa` in *this* repo
fails with "couldn't find remote ref" ([[onprem-gitops-repo-topology]]).

Every `infrastructure/*` Kustomization in `infra.yaml` carries `sourceRef: { name: infra }`,
so `flux reconcile source git flux-system` leaves them all on their cached revision **and
still prints a success line**. Use `flux reconcile kustomization <name> --with-source`.

A third source, `gateway-api-upstream`, pins the upstream CRDs to a tag and is identical
everywhere:

```yaml
  url: https://github.com/kubernetes-sigs/gateway-api
  ref: { tag: v1.4.0 }
  ignore: |
    /*
    !/config/crd
```

---

## 3. What a Kustomization entry looks like

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: trust-manager
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: infra
  path: ./infrastructure/trust-manager
  prune: true
  wait: true
  timeout: 5m
  dependsOn:
  - name: cert-manager
```

`prune: true` means deleting the entry **deletes the workload**. `wait: true` plus `dependsOn`
is how ordering is expressed — and why a stuck dependency cascades
([[flux-stale-dependency-cascade]]). `gateway-api` is the one exception with `prune: false`,
correct for upstream CRDs.

---

## 4. Prod is the best-documented cluster, and says why

`op-usxpress-prod/flux-system/infra.yaml` opens with a 29-line header that is worth reading
before writing any new cluster's file. Its three load-bearing claims:

- **"SELF-CONTAINED BY DESIGN."** Prod owns its own Secrets Manager entries, S3 buckets, IRSA
  roles and Route53 zone in account `937464026810`. No cross-cluster bridge. The one
  deliberate exception is the shared ECR registry `064859874041`.
- **"NOT PHASED — every Kustomization is active."** Explicitly rejecting a commented-out
  "phase 2" appendix, because *"that would require a human to come back and uncomment it,
  which is precisely the manual step we are removing."*
- **`cross-cluster-eso` is intentionally absent** — retired. It is what required the manual
  "Seed Cross-Cluster ESO Token" Octopus runbook in the QA bootstrap checklist.

And one warning earned the hard way, preserved in the file:

> RisingWave … was absent before that on purpose — wiring a path that does not exist is the
> 17-day "path not found" failure, and Flux reports it as a stuck Kustomization rather than an
> error anyone notices.

**That is the same failure class as the console freeze on 2026-09-15**: Flux unable to apply,
reporting it somewhere nobody looks. See ALERTS-TO-BUILD C6.

---

## 5. What a new cluster needs here

Small and mechanical, which is the point:

1. `clusters/<cluster>/flux-system/infra-source.yaml` — the platform repo on branch
   `op-<env>`, plus the pinned gateway-api source.
2. `clusters/<cluster>/flux-system/infra.yaml` — the Kustomization set. Start from **prod's**,
   not QA's: it is self-contained, fully active, and documented.
3. `clusters/<cluster>/flux-system/kustomization.yaml` — enumerate all four files.
4. `gotk-components.yaml` and `gotk-sync.yaml` — written by `flux bootstrap`. Prod's comment
   confirms pre-writing `gotk-sync.yaml` is idempotent: *"`flux bootstrap` with
   flux_target_path=clusters/op-usxpress-prod regenerates exactly this."*
5. **A matching `op-<env>` branch in `iaac-talos-flux-platform`**, which must exist *before*
   bootstrap or the `infra` source cannot resolve.

---

## Proven

- One directory per cluster, single `master`, five files each. Read at `33efcd9`, 2026-09-17.
- Two Git sources per cluster with **different branch models**: the cluster repo on `master`,
  the platform repo on `op-<env>`. A new cluster needs a change in both.
- QA and prod differ only by cluster name, platform branch, prod's documentation header, and
  ordering — no copied-in foreign values found in the files compared.

## Tested and killed

- *"A new cluster needs a PR here, not a branch."* Half right, and the wrong half matters:
  `infra-source.yaml` still references a per-environment branch of the **platform** repo.
  It needs both.

## Traps

- **`clusters/bm-dev` is on-prem dev.** Not `op-usxpress-dev`. `TF_VAR_flux_target_path` for
  development is `clusters/bm-dev`, and `envs/dev.tfvars` said otherwise until 2026-09-17.
- **`dpl2/` is incomplete and `dpl2.bak/` is a committed backup.** Whether either is inert
  depends on nothing pointing at them. Unverified.
- **`.gitkeep` still sits in `op-usxpress-qa/flux-system/`** beside five real files.
- **`prune: true` on nearly every Kustomization** — removing an entry deletes the workload.
- **Flux controller version drift across clusters is unchecked.** `gotk-components.yaml` was
  excluded from the comparison, so whether all clusters run the same Flux is **not known**.
  Settle it with:
  `for C in bm-dev op-usxpress-qa op-usxpress-prod; do echo -n "$C: "; grep -m1 -o 'app.kubernetes.io/version: [^ ]*' clusters/$C/flux-system/gotk-components.yaml; done`

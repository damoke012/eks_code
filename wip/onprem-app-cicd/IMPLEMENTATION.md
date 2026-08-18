# Building the on-prem app CI/CD — implementation pack

**Companion to** [`PLATFORM-CICD-FOR-APPS.md`](PLATFORM-CICD-FOR-APPS.md) (the why and the gap
analysis). This is the how: staged files, target paths, PR order, and what "done" looks like at each
step.

First customer: the RisingWave ETL pipeline. Everything here generalises — `app-risingwave` becomes
`app-<name>` for the second team.

## What's in this directory

```
platform/app-namespaces/       → iaac-talos-flux-platform  (namespace, quota, limits)
platform/kyverno-policies/     → iaac-talos-flux-platform  (registry + digest policies)
argocd/                        → the two Argo CD Applications
terraform/                     → ECR repository + GitHub OIDC push role
app-template/                  → the reference app repo: Dockerfile, apply script,
                                 workflow, kustomize base + overlays
```

Everything has been syntax-checked. Both overlays build under `kubectl kustomize`, all manifests
parse, the workflow parses, `apply.sh` passes `bash -n`. None of it has been applied to a cluster.

## The shape

```
GitHub Actions (GitHub-hosted)          ECR 064859874041                on-prem cluster
──────────────────────────────          ────────────────                ───────────────
push to main
  └─ build image  (SQL + psql
     + apply.sh, nothing env-specific)
  └─ push by digest ──────────────────► risingwave/etl-pipeline
  └─ open PR bumping QA overlay                    │
                                                   │
   PR merged ─────────────────────────────────────►│
                                     Argo CD (QA) syncs deploy/overlays/qa
                                       └─ Sync-hook Job pulls that digest
                                          via ecr-pull-secret
                                          reaches risingwave-frontend:4567
                                          secrets from AWS SM via ESO
                                                   │
   PR bumping prod overlay to the SAME digest ─────►
                                     Argo CD (prod), manual sync
```

Nothing is rebuilt between environments. No image is built on-prem — the build has no cluster
dependency; only the *apply* does, and that runs as a Job Argo CD deploys.

## PR sequence

Each PR is independently revertible and ordered so nothing references something that doesn't exist.

| # | Repo | Path | Contents | Blocks |
|---|---|---|---|---|
| 1 | **TBC — see §Decisions** | — | `terraform/ecr-and-push-role.tf` | 3 |
| 2 | `iaac-talos-flux-platform` (`op-dev`, then `op-qa`, `op-prod`) | `infrastructure/app-namespaces/` | `platform/app-namespaces/` | 4, 5 |
| 3 | `variant-inc/risingwave-pipeline` | repo root | `app-template/` (Dockerfile, apply.sh, workflow, deploy/) | 5 |
| 4 | `iaac-talos-flux-cluster` (`master`) | `clusters/bm-dev/flux-system/infra.yaml` + QA + prod | Kustomization entry for `app-namespaces` | — |
| 5 | `iaac-talos-flux-platform` | `infrastructure/argocd-config/` | `argocd/application-qa.yaml` (QA cluster only) | — |
| 6 | `iaac-talos-flux-platform` | `infrastructure/kyverno-policies/` | `platform/kyverno-policies/` | — |
| 7 | `iaac-talos-flux-platform` | `infrastructure/argocd-config/` | `argocd/application-prod.yaml` | after QA is proven |

PR 6 can go any time — the policies ship in `Audit`, so they report without blocking. Flip to
`Enforce` once the first app is deployed and the policy report is clean.

## Acceptance, step by step

**After PR 1** — a manual `docker push` using the role succeeds; the same role fails against any
other ECR repository.

**After PRs 2 + 4** — on dev and QA:
```bash
kubectl get ns app-risingwave -o jsonpath='{.metadata.labels}' ; echo
kubectl -n app-risingwave get secret ecr-pull-secret          # ⚠️ see §Unknowns
kubectl -n app-risingwave get resourcequota
```

**After PR 3** — a push to `main` builds and pushes, and opens a QA promotion PR carrying a digest.

**After PR 5** — merge the promotion PR, then:
```bash
kubectl -n argocd get application risingwave-etl-qa
kubectl -n app-risingwave get jobs
kubectl -n app-risingwave logs job/etl-pipeline-apply
```
Expect the Job to complete, and the log to end `done: N applied, 0 unchanged`. Re-sync it: the
second run must report `0 applied, N unchanged`. **That idempotency check is the real acceptance
test** — Argo CD re-syncs, and a pipeline that re-applies DDL on every sync will eventually
recreate a streaming job and re-read a topic from `earliest`.

**After PR 7** — the same digest that ran in QA appears in the prod overlay's diff, and prod does
not sync until a human presses Sync.

## Design notes worth keeping

**The apply script refuses a changed file.** If a `.sql`/`.rw` file's hash differs from what was
recorded, it fails rather than re-applying. RisingWave DDL is not a migration system — an edited
`CREATE SOURCE` means dropping and recreating a streaming job, which re-reads the topic. That's a
decision, not something a background sync should make silently. New version, new filename.

**Tracking lives in Postgres, not RisingWave.** RisingWave has no read-write transactions and
rejects `VARCHAR(N)` — the same constraints that ruled out Flyway (INFRA-1491).

**The Job is a Sync hook** with `hook-delete-policy: BeforeHookCreation`, so it re-runs on each sync
and its logs land in the Argo UI, which is where the RisingWave team will watch their deploys.

**`CreateNamespace=false`.** The platform creates `app-*` namespaces with quotas, PSA labels and
Istio enrolment. An app team cannot conjure a namespace by editing an Application.

## Decisions needed

1. **Which repo manages ECR?** `terraform/ecr-and-push-role.tf` targets account **064859874041**
   (infra-common / devops). `iaac-talos` manages 700736442855, so it does not belong there. This is
   the one thing blocking PR 1.
2. **Repo layout** — the app-template assumes manifests live in `variant-inc/risingwave-pipeline`
   alongside the SQL. Simpler for one team; a separate deploy repo scales better. Changing later is
   cheap, changing after three teams have copied it is not.
3. **Prod gate** — currently PR review plus manual Argo sync. Two gates. Confirm that's wanted, or
   drop to one.
4. **Namespace name** — `app-risingwave`. The `apps` AppProject cannot target `risingwave` or
   `risingwave-2`, so this is forced; worth confirming with Idris and Tim that the *name* is right.

## Unknowns — verify before committing to dates

1. ~~Does `ecr-credentials-sync` cover a brand-new namespace?~~ **RESOLVED 2026-08-18 — yes.**
   It enumerates namespaces dynamically from the API, excluding only `kube-system`, `kube-public`,
   `kube-node-lease` and `flux-system`, then creates/updates `ecr-pull-secret` in each. It also
   patches every ServiceAccount in every namespace with `imagePullSecrets`. So `app-risingwave` is
   covered within 5 minutes of creation, with no list to maintain. PR 2 is unblocked.

   Three observations on that CronJob, none blocking, all worth a ticket:
   - It runs `image: public.ecr.aws/aws-cli/aws-cli:latest` — a **mutable tag on a job that holds
     cluster-wide secret-write permissions**. That is the exact thing PR 6's digest policy exists to
     prevent, in the platform's own code. It also explains the three Failed jobs from ~60 days ago:
     a `:latest` roll is the obvious candidate.
   - It depends on `python3` being present inside the aws-cli image. Nothing guarantees that across
     a `:latest` change.
   - Patching **every** ServiceAccount in **every** namespace fights GitOps: any SA whose definition
     is managed by Flux or Helm will drift, get reverted, and be re-patched on the next 5-minute
     run. Worth checking for churn:
     ```bash
     kubectl get events -A --field-selector reason=ServiceAccountUpdated 2>/dev/null | head
     ```
2. **QA and prod have not been through the dev discovery.** Unknown whether `ecr-credentials` is
   wired, whether Argo CD has the same `apps` project, whether ARC exists.
   ```bash
   kubectl get kustomizations -A | grep -E 'argocd|ecr-credentials'
   kubectl -n argocd get appprojects,applications
   ```
3. **Argo CD login for the RisingWave team is not built** (W5). Argo CD ships Dex, but SSO needs an
   identity source — and Entra needs an app registration we can't create ourselves. Until it's
   wired, the team can see their deploys only via `kubectl` or a shared admin login, which is not
   the outcome we want. This is the least-solved item in the whole plan.

## Not doing, deliberately

- **No in-cluster image building.** Building needs no cluster access; GitHub-hosted runners already
  do this for every cloud app. This removes BuildKit/Kaniko on Talos, a second ARC scale set and the
  PodSecurity work that would come with them.
- **No Artifactory or Harbor.** ECR is the house registry, pull already works on-prem, and a
  self-hosted registry is a stateful component to run HA, back up and upgrade for no stated benefit.
- **The existing ARC runner stays** for what it was built for — ad-hoc SQL and anything needing
  in-cluster network — but nothing in the promotion path depends on it.

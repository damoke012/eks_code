# On-prem application CI/CD — what exists, what's missing, what we build

**For:** Idris · **From:** Doke · **Date:** 2026-08-18
**Verified against:** `op-usxpress-dev` (10.10.82.50) on 2026-08-18. QA and prod **not yet verified** — see §7.

## The capability we owe app teams

A team should be able to: commit code, get an image built and pushed to the registry, and have it
deployed to QA and then prod — **without a platform engineer in the loop**, and without being able
to break anything outside their own namespace.

RisingWave is the first customer. Their ETL pipeline is the pilot. This document is the platform
side only; what the RisingWave team needs to change in their SQL is in
[`../rw-etl-promotion/FINDINGS-2026-08-18.md`](../rw-etl-promotion/FINDINGS-2026-08-18.md).

## 1. Answer up front: no, it is not in place

The **deploy** half is built and unused. The **build-and-ship** half and all the glue are missing.

| | State |
|---|---|
| Argo CD installed, per-cluster, Flux-managed | ✅ dev, QA, prod |
| `apps` AppProject restricted to `app-*`, `default` neutered | ✅ proven on dev + QA |
| ECR **pull** into any namespace | ✅ dev (`ecr-credentials-sync`, 29 namespaces) |
| ECR **push** from CI | ❌ no repo, no role, no pipeline |
| An `app-*` namespace existing | ❌ none |
| Any Argo CD Application at all | ❌ zero on dev |
| App repo pattern / manifest layout | ❌ undefined |
| Argo CD login + RBAC for an app team | ❌ not configured |
| Promotion mechanism dev → QA → prod | ❌ undefined |

So: roughly half the substrate, none of the road.

## 2. Which delivery path this is

We deliberately run two:

| Path | For | Deploys via |
|---|---|---|
| **DX / MageRunner** | cloud→on-prem lift-and-shift of existing apps | Octopus + MageRunner ([design doc](../../docs/designs/design_doc_magerunner_bare_metal.md)) |
| **Argo CD** | net-new on-prem workloads | Argo CD, GitOps |

The RisingWave ETL is net-new on-prem, so it's the **Argo CD** path. Both paths share the same
build-and-push half and the same registry; only the deploy half differs.

## 3. The design

```
  GitHub (app repo)
        │  push to main
        ▼
  GitHub Actions  ── GitHub-hosted runner ──────────────────────────────┐
        │  build image  (SQL + psql + apply script, or app binary)      │
        │  push by digest                                              │
        ▼                                                              │
  ECR  064859874041.dkr.ecr.us-east-2.amazonaws.com/<group>/<repo>      │
        │                                                              │
        │  PR bumps QA overlay to @sha256:…                            │
        ▼                                                              │
  Argo CD (op-usxpress-qa)  ──►  namespace app-<name>                   │
        │                        Job / Deployment pulls that digest    │
        │                        via ecr-pull-secret                   │
        │                        secrets resolved per-cluster by ESO   │
        ▼                                                              │
  PR bumps prod overlay to the SAME digest  ──►  Argo CD (prod)  ───────┘
```

**No build happens on the on-prem clusters.** Building an image needs no cluster access, and
GitHub-hosted runners already do this for every cloud app. This is the single biggest
simplification available to us — it removes BuildKit/Kaniko on Talos, a second ARC scale set, and
PodSecurity work, none of which buy anything.

**The in-cluster ARC runner stays for what it was built for.** `arc-runners/risingwave-pipeline`
exists because applying SQL needs to reach `risingwave-frontend:4567`, a ClusterIP with no ingress.
Under this design that work moves into a Kubernetes Job that Argo CD deploys, so the runner becomes
optional rather than load-bearing. Keep it — it's useful for ad-hoc and for anything that genuinely
needs in-cluster network — but nothing in the promotion path depends on it.

**Promotion is a digest in a pull request.** Nothing is rebuilt per environment. What runs in prod
is byte-identical to what passed in dev, and the PR is the audit record. This matches the cloud
standard already documented in `qa_vs_dev_delta.md`: *"same SHA re-tagged from Dev, no rebuild
between environments."*

## 4. Platform work items

Ordered. Each has an acceptance test — if it can't be demonstrated, it isn't done.

### W1 — ECR repository + push identity
Create the repo under the shared registry (account **064859874041**, `infra-common`/devops) and a
role the app repo's GitHub Actions can assume via OIDC, scoped to that repository and to a branch.
We already run this pattern for `gha-op-usxpress-dev-risingwave-pipeline-secrets` (trust pinned to
`refs/heads/master`) — same shape, different permissions.

*Accept:* a workflow run in the app repo pushes an image and can be seen in ECR; the same role
cannot push to any other repository.

### W2 — Confirm ECR pull on QA and prod
Verified on dev: `ecr-credentials-sync` runs every 5 minutes under IRSA and distributes
`ecr-pull-secret` into 29 namespaces. **Unverified on QA and prod.**

*Accept:* `ecr-pull-secret` present in a new `app-*` namespace on all three clusters, and a pod
using it pulls successfully.

### W3 — `app-*` namespace provisioning
No `app-*` namespace exists anywhere. Decide how one is created (Flux platform repo, most likely,
so the platform owns namespace creation, quotas, PSA labels and Istio enrolment) and what it comes
with by default.

*Accept:* `app-risingwave` exists on dev and QA with pull secret, PSA labels, Istio ambient
enrolment and a resource quota, created from git.

### W4 — App repo template
One reference implementation, not a document. Overlays per environment, image referenced **by
digest**, the Argo CD `Application` manifest, and the workflow that builds and opens the promotion
PR.

*Accept:* a second team can copy it and deploy without asking us anything.

### W5 — Argo CD access for app teams
Argo CD ships with Dex. Wire login so the RisingWave team can see their own Application, and set
RBAC so they can view and sync **their** project and nothing else.

*Accept:* an RW engineer logs in, sees `app-risingwave`, can sync it, and cannot see or touch
platform namespaces.

### W6 — Promotion gate
Decide what stands between QA and prod: PR review on the prod overlay is the simplest and is
already auditable. Argo CD sync windows and manual sync are alternatives.

*Accept:* a prod deploy requires a named human approval that is recorded in git.

### W7 — Guardrails worth having early
Kyverno is already installed on all three clusters. Two policies worth adding while there are zero
apps to migrate:
- images must come from the approved ECR registry
- images must be referenced by digest, not tag

*Accept:* a manifest with `:latest` is rejected at admission.

## 5. What this does NOT need

Worth stating so nobody builds them:

- **In-cluster image building** (BuildKit / Kaniko) — the build has no cluster dependency
- **A second ARC scale set** — same reason
- **Artifactory or Harbor** — ECR is the house registry, pull already works on-prem, and a
  self-hosted registry is a stateful platform component to run HA, back up and upgrade for no
  articulated benefit. If there's a requirement (air-gap, egress cost, mandate) it should be stated
  and costed; otherwise ECR.

## 6. Decisions needed

1. **Namespace naming.** The guardrail is `app-*`, so `risingwave` and `risingwave-2` can never be
   Argo CD destinations — deliberately, after the July split-brain. The ETL application would live
   in `app-risingwave`, separate from the RisingWave platform namespaces. Confirm that's the intent.
2. **Repo layout.** App manifests in the same repo as the code, or a separate deploy repo? Same-repo
   is simpler for one team; separate scales better and keeps the promotion PR small.
3. **Who owns the promotion PR** — the app team raising it, or a platform-owned deploy repo they
   raise against.
4. **Prod gate** — PR review, or an Argo CD manual-sync step, or both.

## 7. Not yet verified

The dev numbers above are read from the live cluster. **QA and prod have not been through the same
discovery.** Before committing to dates, run the same block on both:

```bash
kubectl get kustomizations -A | grep -E 'argocd|ecr-credentials'
kubectl -n argocd get appprojects,applications
kubectl get ns | grep -E '^app-|arc-'
kubectl -n ecr-credentials get cronjob
```

Specifically unknown: whether `ecr-credentials` is wired on QA and prod, whether ARC exists there at
all, and whether Argo CD on prod has the same `apps` project. W2 depends on the answers.

## 8. Two live issues on dev, unrelated but ours

Found while reading the cluster; neither is being reported anywhere:

1. **`HelmRelease risingwave-2/prometheus` failing since 2026-07-22.** Rollback failed on a stalled
   `Deployment/prometheus-server`; pod is `1/2 CrashLoopBackOff`, 429 restarts in 36h. It blocks the
   Flux `risingwave` Kustomization health check — 3,837 retries. Chart 29.18.0 there vs 29.25.0 in
   `risingwave`.
2. **cert-manager DNS01 solver falls back to EC2 IMDS**, which doesn't exist on Talos:
   `unable to assume role ... no EC2 IMDS role found`. cert-manager has an IRSA role, so this is
   solver config (`role` / `serviceAccountRef`). `rw-sql-tls-2` will not issue until it's fixed.

# What already exists, and what is actually missing

Written 2026-08-18 after discovering `variant-inc/risingwave-pipeline` and
`variant-inc/iaac-risingwave-cicd`. **Read this before `PLATFORM-CICD-FOR-APPS.md`** —
that document was written believing no app CI/CD existed on-prem. That was wrong.

## What I got wrong

`PLATFORM-CICD-FOR-APPS.md` and `COMMS-TO-TIM-2026-08-18.md` both assert that the ETL
"exists only as DDL applied by hand" and that we "couldn't find it in a repository".
Both are wrong:

* `variant-inc/risingwave-pipeline` holds the SQL, versioned, since May 2026 —
  `pipelines/Brand/{100-sources.rw,200-ingest.rw,300-transform.sql,400-sink.rw}`, a
  `Template/` scaffold, and Idris's `shared/` audit and secret-management files.
* `.github/workflows/pipeline.yaml` (11.5KB) is a working three-stage pipeline —
  validate (SQL guardrails) → approve (GitHub Environment gate) → execute (self-hosted
  in-cluster ARC runner, OIDC to Secrets Manager, `psql`).
* `iaac-risingwave-cicd` documents the architecture, the repo contracts and the runbooks.

Authored by Doke (2026-05-26/27) and extended by Idris (2026-06).

**Do not send the drafted message to Tim as written.**

## Four different things are called "RisingWave" on-prem

Conflating them is what produced the wrong analysis. They are:

| # | Thing | Cluster | Owner | Managed how |
|---|---|---|---|---|
| 1 | `risingwave` ns | op-usxpress-dev | Data team (Tim) | Manually operated; "must not be disrupted" |
| 2 | `risingwave-2` ns | op-usxpress-dev | On-prem platform | GitOps + the SQL pipeline; CI/CD test bed |
| 3 | `risingwave` ns | op-usxpress-qa | Idris (INFRA-1624) | Flux, platform stack |
| 4 | `app-risingwave` ns | op-usxpress-qa / prod | Platform, for app delivery | Created 2026-08-18, Argo CD target |

The documented promotion path is **2 → 1, within dev**, by PR to `iaac-risingwave-onprem`
(which is read-only for the platform team) or applied directly by the data team.
Forward-only. Production never reaches into `risingwave-2`.

## The actual gap

The existing pipeline reaches **`risingwave-2` on op-usxpress-dev only**, and it cannot
reach anything else, for one structural reason stated in the design itself:

> "the RisingWave SQL frontend is a ClusterIP service with no external ingress, so a
> GitHub-hosted runner could never reach it"

The answer was a self-hosted ARC runner **inside op-usxpress-dev**. That is the correct
answer for dev, and it is why the design stops there:

* QA and prod have **no ARC runners** — deliberately excluded from the QA Tier 2 build.
* The OIDC role is scoped to `op-usxpress-dev/risingwave-2/*` secrets in account
  700736442855. QA is 527101283767, prod is 937464026810 — different accounts, different
  issuers, different secrets.
* `iaac-risingwave-cicd`'s "Creating a new environment (QA, staging, prod)" procedure
  creates another **namespace on the dev cluster** (`risingwave-qa`), not an environment
  on the QA cluster. It says so: "For a separate cluster, all of cluster-bootstrap must
  be in place first."

So: **there is no documented path from dev to the op-usxpress-qa cluster.** Not an
oversight in the docs — it has genuinely never been done.

## Two ways to close it

**A. Replicate the runner.** Deploy `arc-controller` + a scale set to QA and prod, add a
per-cluster IAM role and secrets, extend `pipeline.yaml` with an environment matrix.

*For:* one design, already proven, no new concepts. Reuses the guardrails and the
approval gate as-is.

*Against:* it puts a CI runner inside the production cluster that executes SQL on repo
push, holding credentials to the production database. The GitHub Environment gate becomes
the only control between a merge and prod DDL. It also means three ARC installations to
patch, and a registration PAT per cluster.

**B. Package the SQL as an image and let Argo CD run it.** Build the `pipelines/` tree
plus the apply tooling into an image, push to ECR by digest, and run it in-cluster as an
Argo CD **sync-hook Job**.

*For:* solves the same ClusterIP problem — the Job runs *inside* the cluster and reaches
`risingwave-frontend.svc` over cluster DNS — with no runner, no CI credentials in prod,
and no GitHub reachability requirement. Promotion is a digest move, so QA and prod run a
bit-identical artefact. The app team sees their deploy in Argo CD. Kyverno enforces
registry and digest. All of this exists as of 2026-08-18.

*Against:* a second mechanism alongside the existing one, and the apply tooling has to be
packaged rather than installed per-run.

**Recommendation: keep A for dev, add B for QA and prod.** They are complementary. Dev
iterates fast through the runner; a merge to `master` builds the same SQL into an image
that Argo CD promotes onward. The dev pipeline is not replaced or disturbed.

Note the convergence: `iaac-risingwave-cicd` §10's top open item is a
"lightweight, RW-compatible tracking table" to replace the rejected Flyway approach.
`app-template/job/build/apply.sh` implements exactly that — tracks applied files by hash
in Postgres, refuses a file whose hash changed — reached independently from the same
constraints (no read-write transactions, no `VARCHAR(N)`).

## What today's work contributes, regardless of A or B

None of it is wasted, and most of it was fixing defects rather than building for this:

* `ecr-credentials` wired on QA and prod — **neither cluster could pull from ECR at all**.
* Per-cluster IRSA role ARNs corrected — all three platform branches named dev's role.
* `app-namespaces` on QA and prod, with quota, PSA `restricted`, Istio ambient.
* Kyverno registry + digest policies, proven firing on a real image.
* ECR repository `risingwave/etl-pipeline` + a push role scoped to one repo, `master` only.
  (`iaac-risingwave-cicd` §10 already wanted an ECR image for a pre-baked runner.)
* Cross-account ECR pull proven end to end on QA.
* Prod verified — which required break-glass, because prod has no SSO path.

## Ticket corrections

* **INFRA-1634** "Create the RisingWave ETL application repository" — **wrong**. The repo
  exists and is actively maintained. Re-scope to: *extend the existing pipeline to QA and
  prod*.
* **INFRA-1635** (overlays) — still valid under option B.
* **INFRA-1637** (rotate Confluent credentials) — unchanged, still the most urgent item.
* Add: *reconcile `pipelines/Brand/` against what is actually running in dev*.
  `400-sink.rw` is 3.8KB in the repo, and the live dev cluster has **zero sinks**. Repo
  and cluster have diverged, so neither is currently authoritative — promoting today
  would promote a shape that was never run.

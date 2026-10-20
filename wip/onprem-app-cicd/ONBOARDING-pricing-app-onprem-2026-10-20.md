# How on-prem works, and how the pricing app gets onboarded

**Date:** 2026-10-20. **Companion:** `ANALYSIS-octopus-dx-variable-map-2026-10-20.md` (what
Octopus and DX do today). **Model reference:** `ONPREM-CICD.md` — the general path; this
document is the pricing app's instance of it, plus the ways this app does not fit.

**Audience:** Idris, who owns this engagement end to end, and the app team as the
"how it will work" half.

---

## 1. The repo map — four layers, and they are not interchangeable

Getting this wrong has cost a session before: the RisingWave operator is in none of the
places it looks like it should be.

### Layer 1 — the cluster wiring

| Repo | Branch model | Owns |
|---|---|---|
| `variant-inc/iaac-talos` | — | **builds the Talos clusters.** Deployed **through Octopus only** — never a local apply |
| `variant-inc/iaac-talos-flux-cluster` | single `master` | the Flux `GitRepository` + `Kustomization` objects that point at everything else. **The wiring, not the content** |

⚠️ On-prem **dev's** cluster directory is `bm-dev`, not `op-usxpress-dev`. QA and prod use
`op-usxpress-qa` / `op-usxpress-prod`.

### Layer 2 — the platform

| Repo | Branch model | Owns |
|---|---|---|
| `variant-inc/iaac-talos-flux-platform` | **branch per cluster**: `op-dev`, `op-qa`, `op-prod` | everything under `infrastructure/` — app namespaces, routes, Kyverno, Prometheus, RBAC, Reloader, Velero, **Argo CD itself** |

⚠️ Three traps in this one repo, all measured:
* It also has **bare `dev`/`qa`/`prod` branches** beside the `op-*` ones, so a push to
  `qa/...` is rejected as a directory/file conflict and a PR opened against bare `qa` is
  opened against the wrong branch. **Always `--base op-qa`, never the default.**
* Its **default branch is `op-dev`**, so GitHub offers the wrong base every time.
* **Manifests are copies across branches.** `op-qa` and `op-prod` have carried **dev** role
  ARNs. Diff before wiring — but treat it as a prior, not a law; some things really are
  per-cluster.

### Layer 3 — the application product

| Repo | Owns |
|---|---|
| `variant-inc/iaac-risingwave-onprem` | the RisingWave operator and CR — **the product, in neither the platform nor the cluster repo** |
| `variant-inc/iaac-risingwave-2` | Tim's separate `risingwave-2` namespace, wired on `bm-dev` **only** |
| **the pricing app's equivalent — does not exist yet** | see §5, work item **P2** |

⚠️ Every cluster tracks `iaac-risingwave-onprem` at **`branch: main`, 5-minute interval**, so
a merge there **is** a production deploy. That is the one thing not to copy for the pricing
app, and Idris's architecture diagram should show the gate the RisingWave repo lacks.

### Layer 4 — CI/CD

| Repo | Owns | Status |
|---|---|---|
| `usxpressinc/risingwave-poc` | Tim's SQL — the **app-side** repo, in the other org | live |
| `variant-inc/risingwave-pipeline` | the ETL/pipeline build | live |
| `variant-inc/iaac-risingwave-cicd` | **the applier that actually ships** — `build/apply.sh` | live |
| `variant-inc/actions-collection` | shared GitHub Actions (Trivy scan, etc.) | live |
| `variant-inc/usx-cicd-workflows` | **the published reusable workflow app repos call** | repo exists, org access proven 2026-10-07; **the workflow itself is still a draft** in `wip/onprem-app-cicd/cross-org/` |
| `variant-inc/iac-tf-manual-runs` | manually-run Terraform, incl. the **GitHub OIDC push roles** (`apps/common/gha_ecr_push_roles`) | live |
| `variant-inc/iaac-octopus-config`, `iaac-octopus`, `iaac-octopus-server` | Octopus spaces/environments/pools/lifecycles, the worker pods, the server | live |
| `variant-inc/ix-kafka-topics-users` | Kafka topic and user grants — a **separate deployment, often someone else's approval** | live |
| `variant-inc/iaac-confluent-cloud` | Confluent itself | live |

⚠️ **`apply.sh` exists in two repos and only one is built.** The shipped copy is
`iaac-risingwave-cicd/build/apply.sh`; `risingwave-pipeline/build/apply.sh` is built by
nothing, and two reviewed PRs landed in it. Check the build path before reviewing a file.

---

## 2. The delivery path, end to end

```
  app repo (usxpressinc)                    platform (variant-inc)
  ─────────────────────                     ──────────────────────
  merge to master
      │
      ├─► GitHub Actions ──► OIDC role ──► ECR  064859874041
      │   (GitHub-hosted)    one repo,      (immutable tags,
      │                      one branch,     scan on push)
      │                      one repo ARN
      │                                       │
      │                        a workflow on OUR side polls ECR
      │                        and opens the promotion PR HERE
      │                                       │
      │                        values-dev.yaml  ← digest + repository
      │                                       │
      │                            Argo CD dev — automated sync
      │                                       │
      │                        values-qa.yaml  ← the SAME digest
      │                                       │
      │                            Argo CD QA — automated, self-heal
      │                                       │
      │                        values-prod.yaml ← the SAME digest
      │                                       │
      │                            Argo CD prod — A PERSON SYNCS IT
```

**Four properties worth stating**, because each is a decision someone could undo:

* **Build once, promote by digest, never rebuild between environments.** What runs in prod is
  provably the bytes that passed QA. A tag can move; a digest cannot.
* **Builds run on GitHub-hosted runners.** Nothing in CI reaches the on-prem network and no
  CI credential exists inside a cluster. The clusters only pull.
* **The promotion PR is opened on the platform side**, so the app repo needs no write access
  to ours and Argo CD never reads theirs. This is what makes the cross-org question
  disappear.
* **Prod has no `automated` sync policy.** A merge does not deploy to production; a person
  does.

**Environments:**

| | dev | QA | prod |
|---|---|---|---|
| Cluster | op-usxpress-dev (10.10.82.50) | op-usxpress-qa (10.10.82.51) | op-usxpress-prod (10.10.82.52) |
| AWS account | 700736442855 | 527101283767 | 937464026810 |
| Argo CD sync | automated | automated, self-heal | **manual only** |
| Human access | certs (break-glass) | AWS SSO | certs (break-glass) |

The one shared resource across all three is the **ECR registry, `064859874041`**. IAM roles
live in each cluster's own account; there is no cross-cluster bridge.

---

## 3. Where the pricing app does not fit the existing model

`ONPREM-CICD.md` opens with *"Not this path: applications being lifted from cloud EKS. Those
go through DX / MageRunner."* **The pricing app is exactly that case, and it is the first
one.** Five differences, each needing a decision rather than a copy:

| # | The model assumes | The pricing app | Consequence |
|---|---|---|---|
| 1 | the app gets a **new** ECR repo with a push role we create | its build **already pushes to ECR** and Octopus pulls from there | we create **no repo and no push role** — we need a **pull** grant on *their* existing repo. Different Terraform, different failure (403 on manifest HEAD) |
| 2 | the app team writes `deploy/` manifests | they have never written a manifest; **DX generates them** | **we** author the chart and values, from the live cluster's spec. §5 P3 |
| 3 | config arrives as a declaration from the app team | config lives in **Octopus + DX** | read it from the API, propose the split, get Matt's approval |
| 4 | the app exists only on-prem | it **keeps running in cloud** | **two variable stores that will drift.** One direction of copy, with an owner |
| 5 | observability is whatever we provide | they already have a Grafana pattern they rely on | the **OTEL endpoint variables must be carried**, or logging dies green |

**Point 4 is the one most likely to cause an incident** and the one nobody raised on either
call. The app is not migrating; it is being **added**. For as long as both run, a cloud-side
variable fix does not reach on-prem, and the symptom will present as an on-prem fault.

---

## 4. Onboarding, in phases

Each phase ends in something checkable. Owners are from the 2026-10-20 calls.

### Phase 0 — discovery  *(Idris, with Matt and Andres)*

1. **Octopus variable inventory** — `scripts/octopus-dump-app-vars.py --project pricing`.
   Does not need the app team; see the analysis doc §5.
2. **The DX half** — 30 minutes with **Parul or Rohit**: which AWS secrets and services does
   DX create for this app, and what key names does it inject?
3. **Sizing** — read CPU, memory, replicas and probes off the **live DX prod cluster**.
4. **The app's own config code** — Matt: anything the pod reads that nobody declared.
5. **Ping the KNX QA endpoint from on-prem.** This is the **premise of the engagement** and it
   was proven once, months ago. If it fails, the project changes shape and everything after
   this phase is wasted.

**Gate:** a single classification sheet, every variable in one of four cells, **signed off by
Matt**. Not by us.

### Phase 1 — the paper  *(Idris)*

Doke's named deliverables: an **epic**; an **architecture diagram separating platform from
application**; a **repo for the engagement with a README**; a Confluence page for this
engagement **and one for onboarding in general**; **example files** for everything an app team
must produce.

**Gate:** a 10-minute walkthrough to the platform team, the way Parul presented hers.

### Phase 2 — platform build  *(platform)*

Work items in §5. **Gate:** `scripts/onprem-app-wireup-check.sh dev` walks the delivery relay
and prints PASS/FAIL/NOT-MEASURED per gate; `scripts/app-config-coverage.sh` confirms every
declared variable has a home.

### Phase 3 — dev  *(joint)*

**Gate, and it is not a green sync:** the app answers on its own route, the KNX call succeeds
**from the pod**, and **a log line from the pod appears in the Application Monitoring
dashboard**. That last one is the gate that would otherwise be discovered in production.

### Phase 4 — QA, then prod  *(app team opens the PR)*

The same digest, promoted. Prod is synced by a person. Doke: *"as long as it gets into dev and
is following the CI/CD process, that's the majority of the work right there."*

---

## 5. What platform builds

| # | Item | Why it differs from RisingWave |
|---|---|---|
| **P1** | **ECR pull access** for the on-prem accounts on the app's **existing** repository | not a new repo and not a push role. Read the existing policy first — it was written for a consumer in its own account |
| **P2** | the **engagement repo** — chart, `values-{dev,qa,prod}.yaml`, README | the app team cannot write this; DX wrote their manifests |
| **P3** | the **Helm chart**, derived from the live prod Deployment | translation, not authoring. Keep the spec, change only what must change |
| **P4** | `app-pricing` **namespace** via Flux — quota, LimitRange, PodSecurity `restricted`, Istio enrolment | routine |
| **P5** | **Secrets Manager entries + `ExternalSecret`** for the sensitive cell | count the keys in the delivered Secret; ESO writes **partial** secrets on error |
| **P6** | the **OTEL endpoint values** carried into each `values-<env>.yaml` | new. Nothing does this today and nothing reports its absence |
| **P7** | the **promotion workflow** entry (`promotion/apps.json` + `promote.yml`) | the mechanism exists for one app; this is its second consumer, which is the real test of it |
| **P8** | **Argo CD Application** + the app team's **view access** | Argo SSO is live on all three clusters; app-team role mapping is **unexercised** |
| **P9** | **route and DNS** if it serves traffic | external-dns reads the VirtualService annotation; a **copied** VirtualService fails silently |
| **P10** | **the IaC for whatever DX created** that this app needs | the real gap — the "100% IaC coverage" work |

P1, P6 and P10 are the three that have no precedent here. The rest is a second lap.

---

## 6. What we need from the app team

One message, and the list is deliberately short because four of the six questions are **not
theirs to answer** (sizing, manifests, image location, org).

1. **Variable names** from the Octopus project, tagged sensitive / non-sensitive — names,
   never values. We will send a proposal read from the API; they review and approve it.
2. **Anything the app reads that is not in Octopus** — from its configuration code.
3. **The KNX endpoints**, QA and prod, so we can ping them from on-prem.
4. **The current prod version** — 0.1.39, already given.
5. **Whether this app authenticates through Entra.** If yes, flag it: DX recreates the app
   registration on every deploy, with a new client ID, and that is a migration hazard nobody
   has raised.

---

## 7. Open decisions

| # | Decision | Owner | Blocked on |
|---|---|---|---|
| 1 | Which ECR repository and account the app's build actually pushes to | Idris | reading their workflow |
| 2 | Who owns **variable-store reconciliation** while the app runs in both places | Doke | §3 point 4 |
| 3 | Whether the pricing project's **dev deploy is a required merge check** today | Idris | Octopus project settings |
| 4 | Whether aggregated logging on-prem is a **platform** build or per-app wiring | platform | the real gap in the parity table |
| 5 | **Log retention** on-prem, and what cloud's actually is | platform | nobody on the call knew |
| 6 | Whether this app's services (SQL) are **platform-orchestrated** on-prem | joint | Matt says DX may never have provisioned them |

---

## Proven

* **Four repo layers**, two different branch models; `iaac-talos-flux-platform` is branch-per-
  cluster with bare `dev`/`qa`/`prod` decoys and an `op-dev` default.
* The delivery shape: **build once in GitHub Actions, push to ECR `064859874041`, promote the
  same digest by PR, prod synced by a human.**
* On-prem **dev's** cluster dir is `bm-dev`; QA and prod are `op-usxpress-*`.
* `ONPREM-CICD.md` explicitly **excludes** cloud-lift apps, and the pricing app is the first
  one — so five parts of the model need a decision, not a copy.
* The promotion mechanism, the namespace pattern, ESO delivery, Argo CD and its SSO are
  **built and proven**; the reusable caller workflow is **drafted, not published**.

## Tested and killed

* **Creating a new ECR repository and push role for this app.** Killed on the call; the build
  already pushes to ECR.
* **Asking the app team for manifests or sizing.** Killed; DX generated both and they have
  never seen them.
* **Copying the RisingWave repo pattern wholesale.** Killed by its own defect: every cluster
  tracks `branch: main` at 5m, so a merge is a prod deploy. Do not reproduce that.

## Traps

* **`--base op-qa`, never the default.** The bare branch names exist and are a PR trap.
* **A copied manifest carries the source environment's role ARNs and endpoints**, and a copied
  VirtualService fails silently.
* **`apply.sh` lives in two repos and one is built by nothing.** Check the build path.
* **A green Argo sync is not a working deploy**, and a green `ExternalSecret` is not a valid
  value. Judge at the destination — a log line in the dashboard, a successful KNX call from
  the pod.
* **The app keeps running in cloud.** Two variable stores, one direction of copy, and an owner
  — or the first incident after a cloud fix presents as an on-prem fault.
* **Ping KNX from on-prem before Phase 2.** The premise of the engagement is a months-old
  measurement by someone who said so himself.

---

## Appendix — the intake form and the discovery commands

**The intake form** is a published artifact, private to its owner until shared:
`https://claude.ai/artifact/AzVn5mJEnzaQspnKuE3UPV`

It holds three things in a shared record: the application's identity facts, the **variable
inventory** (one row per variable, with the two independent axes — owner and secret-ness —
and the destination each combination implies), and the six questions that block the build.
Seeded 2026-10-20 with what the two calls established: prod version 0.1.39, Matt as the
approver, and real answers to the logs, services, KNX and sign-off questions. The variable
table starts empty on purpose; it is filled from the scripts below, not by typing.

The form refuses a `NAME=value` paste, and says why: values never belong in it.

**The two discovery scripts**, both read-only:

| Script | Reads | Needs |
|---|---|---|
| `scripts/octopus-dump-app-vars.py --project <name>` | Octopus project + library variables: names, environment scopes, sensitive flags | `~/.octopus-api-key` |
| `scripts/discover-cloud-app.sh --context <ctx> -n <ns> --app <workload>` | the running cloud deployment | kubectl context; `--aws-profile` for the Secrets Manager half |

`discover-cloud-app.sh` answers the things no repo holds: **which ECR account, region and
repository the image actually comes from** (parsed from the running image reference, never
assumed), the CPU/memory/replicas/probes DX generated, **every environment variable with its
source** — literal, ConfigMap or Secret — the key names in each ConfigMap and Secret with any
**empty** key marked, the `managedFields` record of what last wrote the object, whether the
workload carries Entra/auth variables, whether it carries **OTEL variables**, and which
Secrets Manager secrets exist for it.

It prints secret **key names** only; values pass through `jq` and never reach stdout.
ConfigMap values print only with `--values`, because a ConfigMap is where a leaked credential
usually hides.

Three guards worth knowing, because each one has burned a previous session:

* **`--context` is required.** An empty `--context` silently selects the current context; on
  2026-10-09 that sent four on-prem queries to a cloud cluster and the output read as a
  finding about on-prem.
* **Every failure says NOT MEASURED and names which fault** — context absent from the
  kubeconfig, no session, profile not configured, RBAC. A login cannot fix a profile that
  does not exist, and collapsing those into one message sends you to the wrong fix.
* **An empty match is reported as a bad filter**, not as absence, with the shorter search to
  try. `--find <substring>` lists candidate workloads so the exact name never has to be
  guessed.

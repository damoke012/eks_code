# RisingWave pipeline promotion — the process

**Audience:** Tim (data team) and Idris (on-prem platform).
**Purpose:** how the RisingWave SQL pipeline moves from dev to QA to prod, what changes,
what does not, and who does which part.
**Companion:** [`ONPREM-CICD.md`](ONPREM-CICD.md) — the generic platform process. This
document is only the RisingWave-specific application of it.

---

## 1. Where things stand

Three things already exist and are **not** being replaced:

* **`variant-inc/risingwave-pipeline`** — the SQL, versioned since May 2026.
  `pipelines/Brand/` (sources, ingest, transform, sink), a `Template/` scaffold, and
  `shared/` audit and secret-management files.
* **`.github/workflows/pipeline.yaml`** — a working three-stage pipeline:
  validate (SQL guardrails) → approve (GitHub Environment gate) → execute (self-hosted
  in-cluster ARC runner, OIDC to Secrets Manager, `psql`). Built by Doke, extended by Idris.
* **`iaac-risingwave-cicd`** — the architecture, repo contracts and runbooks.

The design is sound and the reasoning behind it is right: RisingWave's SQL frontend is
`ClusterIP` with no external route, so a GitHub-hosted runner cannot reach it, and an
in-cluster ARC runner can.

---

## 1a. Progress — 2026-08-18/19

**The build and push half is proven end to end.** This had never been done before.

| Step | Status |
|---|---|
| GitHub Actions assumes the ECR push role via OIDC | ✅ |
| Image built and pushed to ECR **by digest** | ✅ `sha256:d6162426…` from commit `987ea1ca` |
| Immutable tags refuse an overwrite | ✅ confirmed on a re-dispatch |
| QA overlay bumped to that digest on `master` | ✅ |
| ApplicationSet targets `master` | ✅ |
| **Argo CD reads the repository** | ❌ **no Git credential exists** (INFRA-1647) |
| Job runs in-cluster | blocked behind the above |

Merged: `iaac-talos-flux-platform#96` (ApplicationSet → `master`),
`risingwave-pipeline#9` (the scaffold), `#10` (disable the inherited Octopus push),
`#11` (digest promotion).

### Three defects found by doing it, rather than by design

1. **The ECR push role needed read on its own repository.** `buildx` reads the manifest
   back after pushing, so the build failed *after* every layer had uploaded, with a message
   that reads like a push permission problem. Corrected — `ecr:BatchGetImage`,
   `GetDownloadUrlForLayer`, `DescribeImages`, still scoped to the one repository.
2. **`build.yaml` had been failing on every push in `risingwave-pipeline`** — the inherited
   cloud Octopus workflow, triggering on `"**"`. It red-flagged every pull request in that
   repository since the fork. Trigger disabled (kept, not deleted). This unblocks everyone's
   PRs there, not just this work.
3. **Argo CD holds no Git credential at all** on op-usxpress-qa — no secret carries the
   `argocd.argoproj.io/secret-type` label. `risingwave-pipeline` is INTERNAL, so Argo cannot
   read it. **This blocks every private application repository**, and it was invisible until
   the first real deploy because the Application pointed at a path that did not exist and
   never got as far as authenticating.

### What is in the repository now

`build/Dockerfile`, `build/apply.sh`, `smoke/001-connectivity.rw`,
`.github/workflows/build-and-push.yml`, and `deploy/base` plus
`deploy/overlays/{qa,prod}`.

`pipeline.yaml` and the ARC runner are untouched. Dev is unchanged.

The first deploy will run `smoke/` only — `SELECT version(); SELECT 1` — proving the chain
without touching any real pipeline. `PIPELINE_DIR` switches to `/pipeline/pipelines/Brand`
once §5 is settled.

## 2. What is actually missing

That pipeline reaches **`risingwave-2` on `op-usxpress-dev`, and nothing else**:

* QA and prod have **no ARC runners** — excluded from the QA Tier 2 build.
* Its IAM role is scoped to `op-usxpress-dev/risingwave-2/*` in account 700736442855.
  QA is 527101283767 and prod is 937464026810 — different accounts, different OIDC issuers.
* `iaac-risingwave-cicd`'s "Creating a new environment" procedure creates another
  **namespace on the dev cluster**, not an environment on the QA cluster.

So there is no path from dev to the QA cluster. That is the gap, and it is the whole of it.

## 3. The four different "RisingWave"s

Conflating these produces wrong conclusions. They are distinct:

| # | Thing | Cluster | Owner | How it is managed |
|---|---|---|---|---|
| 1 | `risingwave` ns | op-dev | Tim | Manually operated. Must not be disrupted |
| 2 | `risingwave-2` ns | op-dev | Platform | GitOps + the SQL pipeline; CI/CD test bed |
| 3 | `risingwave` ns | op-qa | Idris (INFRA-1624) | Flux platform stack |
| 4 | `app-risingwave` ns | op-qa, op-prod | Platform, for app delivery | Argo CD target, created 2026-08-18 |

Promotion today is **2 → 1, inside dev**, by PR to `iaac-risingwave-onprem` or applied by
the data team. Forward-only. What we are adding is a path to **3**, via **4**.

## 4. What changes, and what does not

**Does not change.** Tim's dev workflow. The `risingwave` namespace on dev. The ARC runner
and `pipeline.yaml`, which stay exactly as they are for dev iteration.

**Changes.** A merge to `master` additionally builds `pipelines/` plus the apply tooling
into an image, pushes it to ECR by digest, and Argo CD runs it as a Job **inside** the QA
cluster. The Job reaches `risingwave-frontend` over cluster DNS — the same property the
runner gives us — with no runner and no CI credential in QA or prod. Promotion to prod
moves the identical digest.

## 5. The blocking question — repo and cluster have diverged

`pipelines/Brand/400-sink.rw` is 3.8KB and defines sinks. The live `risingwave` namespace
on op-dev has **zero sinks** — it runs Kafka source → `brand_mv_raw` → `brand_mv_state`
(dedupe on MAX offset) → `brand_mv_flat` and stops.

So neither the repository nor the running cluster is currently authoritative. Promoting
today would promote a shape that was never actually run.

**This must be settled before anything is promoted** (INFRA-1644). It is a question only
the data team can answer:

1. Is `pipelines/Brand/` the intended definition with sinks yet to be applied, or has the
   live pipeline moved on and the repo is behind?
2. Is `brand_mv_flat` the endpoint today, or are the sinks the direction of travel?
3. Are there objects on dev that should **not** be promoted — experiments, scratch views?

## 6. The credentials — needs doing regardless

The Confluent Cloud SASL username and password are stored in the source definition in
plaintext. They are readable from `rw_catalog.rw_sources.connector_props` by anyone with a
SQL session on the cluster. RisingWave's own `rw_catalog.rw_secrets` already holds 15
secrets, but the source DDL inlines the literals rather than referencing them.

Target state: the values live in AWS Secrets Manager, are delivered to the cluster by
External Secrets, and the DDL references them via `SECRET` — nothing sensitive in git,
nothing sensitive in the image.

That means **rotating** them, so we need to know who owns them. Tracked as INFRA-1637, and
it does not depend on any of the CI/CD work.

## 7. Who does what

### Tim — data team
* Settle §5: what the brand pipeline is supposed to be, and make the repo match.
* Confirm which objects on dev should not be promoted.
* Identify who owns the Confluent Cloud credentials and can rotate them.
* Own the SQL and what the pipeline computes — before, during and after this change.

### Idris — platform
* `deploy/overlays/qa` and `deploy/overlays/prod` in `risingwave-pipeline`, pinned by
  digest (INFRA-1635).
* Per-environment Secrets Manager paths for QA and prod, and the `ExternalSecret` that
  delivers them.
* The ApplicationSet entry for prod (INFRA-1636) — with **no** automated sync.
* Move the Confluent credentials to Secrets Manager and rewrite the source DDL to use
  `SECRET` (INFRA-1637).

### Platform — already done (2026-08-18)
* `app-risingwave` namespace on QA and prod, with quota, PodSecurity `restricted` and
  Istio ambient.
* ECR pull working on QA and prod. Neither cluster could pull from ECR at all before this.
* ECR repository `risingwave/etl-pipeline` and a push role scoped to
  `variant-inc/risingwave-pipeline` on `master`.
* Kyverno registry and digest policies, proven firing on a real image.
* The QA ApplicationSet, generating the `risingwave-etl` Application.

### Platform — outstanding
* **Argo CD Git credential (INFRA-1647) — the current blocker.** A `repo-creds` secret
  scoped to `https://github.com/variant-inc`, delivered by External Secrets and applied by
  Flux. Org-scoped rather than per-repo, so onboarding the next app needs no new credential.
  It needs a token minted for Argo CD and stored in Secrets Manager — not the classic PAT
  hand-patched into `flux-system` on 2026-08-18, which is itself unresolved (INFRA-1642).
* **Finish the smoke test (INFRA-1648)** once the credential exists.
* QA's RisingWave L4 routes carry dev hostnames and bind to a Gateway that does not exist,
  so QA has no SQL access over a URL (INFRA-1645).

## 8. Sequence

| Order | Work | Ticket | Depends on |
|---|---|---|---|
| 1 | Rotate the Confluent credentials | INFRA-1637 | who owns them |
| 2 | Settle the repo/cluster drift | INFRA-1644 | Tim |
| 3 | ~~Fix `targetRevision` main → master~~ | done | — |
| 4 | ~~Build workflow + QA overlay~~ | done | — |
| 5 | Argo CD Git credential | INFRA-1647 | — |
| 5b | Finish the smoke test | INFRA-1648 | 5 |
| 6 | Swap in the real `pipelines/` tree | INFRA-1635 | 2, 5 |
| 7 | Prod ApplicationSet + prod overlay | INFRA-1636 | 6 |

Steps 1 and 2 are people questions and should start now. Steps 3–5 are platform work that
can proceed in parallel, because the smoke test deliberately uses a trivial payload and
does not depend on the drift being resolved.

## 9. Decisions still open

* **What the brand pipeline is supposed to be** (§5) — Tim.
* **Who owns the Confluent credentials** (§6) — Tim, or whoever provisioned Confluent.
* **Whether QA gets its own RisingWave SQL hostname** — needed for human debugging, not
  for the pipeline (INFRA-1645).
* **Argo CD SSO for the data team** — so Tim can see his own deploys rather than asking us.
  Blocked on an Entra app registration nobody on the platform team can create (INFRA-1639).

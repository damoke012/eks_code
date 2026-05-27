# On-Prem RisingWave-2 SQL Pipeline — CICD Guide

> **Audience:** RisingWave platform/on-prem team (Doke, Idris) and anyone authoring or
> operating SQL pipelines against the on-prem cluster.
> **Scope:** the GitOps CICD that takes a `.sql`/`.rw` file in this repo and applies it
> to the live **`risingwave-2`** namespace on the **`op-usxpress-dev`** Talos cluster.
> For local Docker-Compose development, see [`README.md`](README.md) (Tim's upstream design).

Last updated: **2026-05-27**.

---

## 1. What this is

This repo is the on-prem platform fork of `usxpressinc/risingwave-poc`. Beyond the local
dev tooling it inherits, it now carries a **continuous-deployment pipeline** that runs SQL
against a real, in-cluster RisingWave deployment with an approval gate and safety guardrails.

The design goal: a developer commits a SQL file under `pipelines/`, and — after validation
and a human approval — it is applied to RisingWave-2 automatically, from **inside the
cluster**, with no manual `kubectl`/`psql` and no externally-exposed database.

| Property | Value |
| --- | --- |
| Cluster | `op-usxpress-dev` (Talos, on-prem) |
| Namespace | `risingwave-2` (isolated from Tim's production `risingwave` ns) |
| AWS account | `700736442855` (USX-Development) |
| Repo | `variant-inc/risingwave-pipeline` |
| Working branch | `feat/onprem-rw2-adaptation` (PR to `master` pending — see §10) |
| Owner | On-prem RisingWave platform team |

> **Isolation guarantee.** Everything here targets `risingwave-2` ONLY. Separate namespace,
> separate IAM role, separate S3 (hummock) bucket, and Secrets Manager paths scoped to
> `risingwave-2/*`. The pipeline literally cannot read or write Tim's production `risingwave`
> namespace or its secrets. See §5.

---

## 2. End-to-end flow

```
 Developer                          GitHub Actions                         op-usxpress-dev cluster
 ─────────                          ──────────────                         ───────────────────────
 edit pipelines/**.sql|.rw   push    ┌──────────┐   ┌─────────┐  ┌─────────┐
 ───────────────────────────────►   │ validate │──►│ approve │─►│ execute │
        (to master)                  └──────────┘   └─────────┘  └────┬────┘
                                     guardrails +   human gate   runs on SELF-HOSTED
                                     change detect  (Environment) in-cluster runner
                                                                      │
                                          OIDC → AWS STS → Secrets Manager (risingwave-2/*)
                                                                      │  psql
                                                                      ▼
                                              risingwave-frontend.risingwave-2.svc:4567  (.rw)
                                              postgres-postgresql.risingwave-2.svc:5432  (.sql)
```

The crucial design decision is the **self-hosted, in-cluster runner**: the RisingWave SQL
frontend is a `ClusterIP` service with **no external ingress**, so a GitHub-hosted runner
could never reach it. A runner living inside the cluster reaches it over plain in-cluster DNS.

---

## 3. The pipeline workflow (`.github/workflows/pipeline.yaml`)

**Trigger:** `push` to `master`, restricted to `paths: pipelines/**`.

Three jobs run in sequence: `validate → approve → execute`.

### 3.1 `validate` (GitHub-hosted `ubuntu-latest`)
- **Change detection.** Diffs `github.event.before..github.sha` for changed `pipelines/**`
  files ending in `.sql` or `.rw`. On the first push to a branch it lists all such files.
- **SQL guardrails.** Fails the run if any changed file contains:
  - `DROP TABLE | DATABASE | SCHEMA | VIEW | MATERIALIZED VIEW | SEQUENCE | INDEX | TYPE | FUNCTION | PROCEDURE`
  - `TRUNCATE`
  - `DELETE FROM <table>` with **no `WHERE` clause**
  - common SQL-injection fingerprints (tautology `OR`, `UNION SELECT`, statement-stacking with DROP/DELETE/TRUNCATE)

  This is a guardrail, not a security boundary — it protects against fat-finger
  destructive DDL, not a malicious committer (who has repo write access anyway).

### 3.2 `approve` (GitHub-hosted `ubuntu-latest`)
- Uses the GitHub **Environment `pipeline-approval`** as a pause gate. The run halts here
  until a required reviewer approves. Configure reviewers under
  *Settings → Environments → pipeline-approval → Required reviewers*.
- **Status:** the Environment isn't yet configured with reviewers. Until it is, GitHub
  auto-creates it with no protection and the job passes straight through. Add reviewers
  before treating this as a real gate (see §10).

### 3.3 `execute` (SELF-HOSTED `risingwave-pipeline`)
Runs on the in-cluster runner. Steps:
1. **Checkout.**
2. **Install tooling** — the minimal ARC runner image lacks `aws` CLI and `jq`; this step
   installs them (and `unzip`/`curl`). `psql` is installed by a later step. *(Followup:
   bake a custom runner image with these preinstalled — see §10.)*
3. **Configure AWS via OIDC** — assumes the IAM role (§5) via GitHub OIDC. No static keys.
4. **Pull secrets** — reads `op-usxpress-dev/risingwave-2/postgres` and
   `.../risingwave-2/root` from Secrets Manager, masks them in logs.
5. **Install PostgreSQL client** (`postgresql-client-16`).
6. **Execute** — for each changed file:
   - `*.sql` → `psql` to **postgres** (`-d postgres`) using the postgres credentials.
   - `*.rw`  → `psql` to **RisingWave** (`-d dev -U root`). RW files are pre-processed to
     strip `sqllogictest` directives (comment lines, `statement`/`query` headers, and
     `---` result blocks) so a `.rw` test file can be replayed as plain SQL.
7. **Workflow summary** — writes commit/actor/status to the GitHub step summary.

---

## 4. The self-hosted runner (Actions Runner Controller)

Why ARC: an ephemeral, repo-scoped runner that lives in the cluster, scales from **zero**,
and reaches `risingwave-2` services directly. Idle cost is ~one lightweight listener pod.

### 4.1 Components

| Piece | Namespace | What |
| --- | --- | --- |
| `gha-runner-scale-set-controller` (chart `0.14.2`) | `arc-systems` | the ARC controller |
| Listener pod `risingwave-pipeline-*-listener` | `arc-systems` | long-polls GitHub for queued jobs |
| `gha-runner-scale-set` (chart `0.14.2`) | `arc-runners` | the scale set `risingwave-pipeline` (`minRunners: 0`, `maxRunners: 2`) |
| Ephemeral runner pods `risingwave-pipeline-*-runner-*` | `arc-runners` | spawned per job, terminated after |
| `arc-runner-pat` ExternalSecret | `arc-runners` | PAT for runner registration (from Secrets Manager) |

The scale-set name `risingwave-pipeline` is what `runs-on: risingwave-pipeline` matches in
`pipeline.yaml`.

### 4.2 Lifecycle (proven 2026-05-27)
1. A job with `runs-on: risingwave-pipeline` is queued in GitHub.
2. The listener (already authenticated) sees it and tells the controller to scale up.
3. An ephemeral runner pod is created in `arc-runners`, runs the job, then terminates.
4. Scale set returns to zero pods.

> **Note for operators:** because `minRunners: 0`, there is **no runner pod at idle** — only
> the listener in `arc-systems`. A registered scale set also does **not** appear under
> `gh api repos/.../actions/runners` until a runner is actively executing. The proof of a
> healthy registration is the **listener pod running** + `AutoscalingRunnerSet` `Phase: Running`.

### 4.3 GitOps deployment (Flux)
The runner is **not** applied by hand — it is GitOps, like everything on this cluster:

| Repo | Path / change | Purpose |
| --- | --- | --- |
| `iaac-talos-flux-platform` (`op-dev`) | `infrastructure/arc-controller/` | controller HelmRelease + OCI `HelmRepository` (`oci://ghcr.io/actions/actions-runner-controller-charts`) |
| `iaac-talos-flux-platform` (`op-dev`) | `infrastructure/arc-runner-rw-pipeline/` | scale-set HelmRelease + PAT `ExternalSecret` + namespace |
| `iaac-talos-flux-cluster` (`master`) | `clusters/bm-dev/flux-system/infra.yaml` | two Flux `Kustomization`s wiring the above |

`arc-runner-rw-pipeline` `dependsOn` `arc-controller` (needs the CRDs first) and the
`external-secrets` operator (needs the controller + the `default` ClusterSecretStore for the PAT).

---

## 5. Security model (OIDC + IAM)

No static AWS keys exist anywhere in this pipeline. The `execute` job authenticates to AWS
with a short-lived token via GitHub OIDC:

```
GitHub Actions OIDC token  ──►  AWS STS AssumeRoleWithWebIdentity  ──►  role:
    gha-op-usxpress-dev-risingwave-pipeline-secrets   (account 700736442855)
```

- **Trust policy** is scoped to `repo:variant-inc/risingwave-pipeline:ref:refs/heads/master`.
  → Only workflow runs on the **`master`** branch can assume the role. Runs on feature
  branches (or forks) get an OIDC token whose `sub` claim does not match, and STS denies them.
  This is intentional defense-in-depth, and it is why the full pipeline can only be smoke-tested
  on `master` (see §9–10).
- **Permissions** are scoped to `secretsmanager:GetSecretValue`/`DescribeSecret` on
  `op-usxpress-dev/risingwave-2/*` only (plus `ListSecrets`). The role **cannot** read Tim's
  production `risingwave/*` secrets.
- OIDC on Talos is served via a CloudFront-fronted OIDC discovery endpoint (the cluster's
  IRSA mechanism), so AWS can validate the cluster/GitHub tokens without EKS.

Role shipped via `iaac-talos` PR #30 (Terraform, applied through Octopus release 1.143).

---

## 6. Secrets & connection details

### 6.1 In AWS Secrets Manager (the source of truth)
| Secret | Contents | Consumed by |
| --- | --- | --- |
| `op-usxpress-dev/risingwave-2/postgres` | `{username,password}` | `execute` job (`.sql` files) |
| `op-usxpress-dev/risingwave-2/root` | `{password}` (RW `root`) | `execute` job (`.rw` files) |
| `op-usxpress-dev/risingwave-2/rw-license-key` | RW enterprise license JWT | RisingWave platform (not the pipeline) |
| `op-usxpress-dev/risingwave-pipeline/github-runner-pat` | `{github_token}` | runner registration (via ExternalSecret) |

### 6.2 GitHub repo secrets (connection coordinates only — **no credentials**)
| Secret | Value |
| --- | --- |
| `RISINGWAVE_HOST` | `risingwave-frontend.risingwave-2.svc.cluster.local` |
| `RISINGWAVE_PORT` | `4567` |
| `POSTGRES_HOST` | `postgres-postgresql.risingwave-2.svc.cluster.local` |
| `POSTGRES_PORT` | `5432` |

These are non-sensitive (they're just in-cluster DNS names) — the actual credentials are
pulled at runtime from Secrets Manager via OIDC.

### 6.3 In-cluster service endpoints
| Service | ClusterIP:port | Notes |
| --- | --- | --- |
| `risingwave-frontend` | `:4567` | RisingWave SQL (pg-wire). Connect as `root`, db `dev`. |
| `postgres-postgresql` | `:5432` | Backing PostgreSQL (Bitnami chart). |

---

## 7. RisingWave SQL — compatibility notes for pipeline authors

RisingWave is **not** drop-in PostgreSQL. These were learned empirically while evaluating a
migration framework:

- **No `VARCHAR(N)` length specifiers.** Use bare `VARCHAR` / `CHARACTER VARYING`. A length
  qualifier is rejected.
- **No read-write transactions.** RisingWave is effectively autocommit; you cannot wrap DDL in
  `BEGIN … COMMIT` and roll back. Each statement stands alone.
- **Flyway was evaluated and rejected.** Flyway's `flyway_schema_history` bookkeeping relies on
  a read-write transaction and types RW doesn't accept, so a Flyway-based migration approach
  does not work against RisingWave. We therefore keep the **file-change-detection** model
  (this pipeline) and plan a lightweight, RW-compatible tracking table instead (§10).

### `.sql` vs `.rw` convention
- `.sql` → applied to the backing **PostgreSQL**.
- `.rw`  → applied to **RisingWave**; may use `sqllogictest` directives (which the pipeline
  strips before execution), so RW regression-style test files can double as deployable SQL.

---

## 8. How to add and run a pipeline

1. Add (or edit) a file under `pipelines/` ending in `.sql` or `.rw`.
2. Make sure it passes the guardrails (no destructive DDL, no `DELETE` without `WHERE`, etc.).
3. Merge it to `master` (the pipeline triggers on push to `master`, `paths: pipelines/**`).
4. The run pauses at `approve` — a required reviewer approves in the GitHub UI.
5. `execute` applies it in-cluster and writes a summary.

Example RW statement (Tim's secret-manager pattern) suitable for a `.rw` file:

```sql
CREATE SECRET dev_kafka_prefix WITH (backend = 'meta') AS '<value>';
```

---

## 9. Verification done so far (2026-05-27)

- **Runner + in-cluster network — PROVEN.** A throwaway `runner-healthcheck.yaml` workflow ran
  on `risingwave-pipeline` (GH Actions run `26536028292`, ✓ in 3s). It confirmed:
  - the scale set spawned an ephemeral runner pod from zero (Ubuntu 24.04, user `runner`),
  - in-cluster DNS resolved both services, and
  - **`TCP OPEN`** to `risingwave-frontend:4567` **and** `postgres-postgresql:5432`
    (i.e. no NetworkPolicy blocks `arc-runners → risingwave-2`).
- **Full SQL execution — NOT yet run.** It requires the run to be on `master` (OIDC trust is
  `master`-only, §5). Deferred to the master merge (§10).

---

## 10. Open items / roadmap

| Item | Notes |
| --- | --- |
| **Tracking-table + apply-all bootstrap** | RW-compatible alternative to Flyway: a lightweight table recording applied files + an apply-all mode for first bootstrap. To be added to `pipeline.yaml` before the master PR. |
| **Full SQL smoke-test on `master`** | Run Tim's `CREATE SECRET` example end-to-end (OIDC → SM → psql → RW) once on master. |
| **`pipeline-approval` reviewers** | Configure required reviewers on the Environment so the approve gate is real. |
| **Disable `build.yaml`** | The inherited "Push to Octopus" workflow fails on every push (cloud Octopus push — irrelevant on-prem). Neuter its trigger. |
| **Remove `runner-healthcheck.yaml` + `.runner-healthcheck`** | Test scaffolding; delete before the master PR. |
| **Custom runner image** | Pre-bake `aws`/`jq`/`psql` into an ECR image to cut ~30–40s of per-run install time. |
| **PR `feat/onprem-rw2-adaptation` → `master`** | After Idris signoff + the tracking-table extension. |

---

## 11. Repo / infrastructure map

| Repo | Role |
| --- | --- |
| `variant-inc/risingwave-pipeline` (this repo) | SQL pipeline files + `pipeline.yaml` CICD |
| `variant-inc/iaac-risingwave-2` | RisingWave-2 data-plane manifests (Flux) + ExternalSecrets |
| `variant-inc/iaac-talos` | Terraform: IAM (OIDC role), S3 hummock bucket, cluster |
| `iaac-talos-flux-platform` (`op-dev`) | ARC controller + runner scale set (Flux infrastructure) |
| `iaac-talos-flux-cluster` (`master`) | cluster Kustomizations wiring the platform infra |
| `variant-inc/iaac-risingwave-cicd` | broader RisingWave CICD architecture docs |

---

*Maintained by the on-prem RisingWave platform team. Questions: Doke / Idris.*

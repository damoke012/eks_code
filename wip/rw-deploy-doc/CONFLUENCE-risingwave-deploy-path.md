# Deploying a RisingWave SQL change: dev, QA and production

**Audience:** anyone changing SQL pipelines in `usxpressinc/risingwave`.
**Scope:** from a feature branch to objects existing in the RisingWave catalog on-prem.
**Last verified:** 21 October 2026, measured at each hop on a real run.

---

## In one paragraph

You work on a branch and open a pull request. The moment it merges to `master`, everything
to dev happens without anyone watching: the image builds, it is scanned, it is pushed to
ECR, a timer promotes it, Argo CD applies it, and your SQL runs. That took about twenty
minutes end to end. QA and production do not move on their own. A person runs the promotion
for QA, and production additionally needs a second person to merge a pull request.

> **Insert the Lucid diagram here.** Import source is in the repo at
> `wip/rw-deploy-doc/lucid-import.mmd` (Lucid: File → Import → Mermaid).

---

## Before you start

| You need | Why |
|---|---|
| Write access to `usxpressinc/risingwave` | to push a branch and merge a pull request |
| Docker locally | to test the pipeline before pushing |
| Access to `argocd.op-dev.usxpress.io` | to watch the deploy (optional but useful) |
| `kubectl` with the op-dev kubeconfig | to verify the result in the database (optional) |

Nothing else. You never need AWS credentials, and you never put a secret in the repo.

---

## Part 1 — Make the change

1. **Branch off master.**

   ```
   git checkout master && git pull
   git checkout -b your-change
   ```

2. **Edit the pipeline.**

   | What | Where |
   |---|---|
   | RisingWave SQL | `pipelines/<NNN-Entity>/*.rw` |
   | Postgres SQL | `pipelines/<NNN-Entity>/*.sql` |
   | Non-secret config | `pipelines/config/dev.env` and `qa.env` |
   | Anything secret | AWS Secrets Manager. Ask the platform team. Never a file. |

   Files apply in filename order, which is what the number prefixes are for.

3. **Test locally** with the docker compose stack in the repo.

   Set `MONGODB_CONNECTION_STRING` to your local container rather than splitting it into
   host, port, username and password. The same variable then works on your laptop and in
   the cluster, and the cluster target is an Atlas `mongodb+srv` endpoint that has no port
   to split out.

4. **Push the branch.**

   ```
   git push -u origin your-change
   ```

5. **Open a pull request.**

   GitHub shows a banner on the repository page after a push. Otherwise: **Pull requests**
   tab → **New pull request** → base `master`, compare your branch → **Create pull request**.

6. **Merge it.** Squash and merge. If the repository requires a review, request one.

**Nothing builds until the change is on `master`.** A branch push does not trigger the build,
and the AWS trust policy accepts only `master`, so a branch could not get credentials even
if it did.

> **To exercise the pipeline without merging:** **Actions** tab → **build-sql-image** →
> **Run workflow**, on `master`.

---

## Part 2 — What the build does

Starts automatically on merge. Watch it under **Actions → build-sql-image**.

| Step | What it does | What stops it |
|---|---|---|
| 1 | Checks `pipelines/` actually contains SQL | An empty directory. An image applying nothing would deploy green and do nothing. |
| 2 | Gets a short-lived AWS session over OIDC | Nothing is stored, so there is nothing to leak or rotate. |
| 3 | Builds the image: the platform's applier base with your `pipelines/` copied in | You need no Dockerfile. |
| 4 | Scans for critical vulnerabilities | A critical finding, while the image is still local. |
| 5 | Pushes to ECR, identified by digest | A digest names content, so it cannot be moved underneath you. |

The build takes about a minute.

---

## Part 3 — How dev picks it up

Two mechanisms, running independently.

1. **The promotion job runs every ten minutes.** It reads the ECR repository, takes the most
   recently pushed image, and compares that digest with the one `values-dev.yaml` names.

2. **If they differ it edits the file and merges itself.** You will see a commit on the chart
   repository reading `promote: dev to sha256:…`. It verifies its own edit landed before
   committing, so a silent miss cannot report success.

3. **Argo CD notices the commit.** It polls the chart repository and compares what Git says
   against what is running. The Application is `risingwave-etl`.

4. **Argo replaces the apply job.** The digest changed, so the job's pod template changed,
   and a Kubernetes job's template cannot be edited in place. Argo deletes the old job and
   creates a new one. **This is also why a previously failed job does not block the next
   attempt.**

5. **The job runs your SQL.** It loads `pipelines/config/dev.env`, checks every required
   value is present and non-empty, then applies your files in filename order.

6. **The job deletes itself on success,** and the log goes with it. If you want the log,
   read it while the pod still exists.

**Measured on 21 October 2026**

| Event | Time (UTC) |
|---|---|
| Pushed to master | 23:24 |
| Image in ECR | 23:24:53 |
| Promotion committed the digest | 23:36:22 |
| Apply job completed | 13 seconds after it started |

---

## Part 4 — Proving it worked

A green job means the script exited zero. What proves your change is the objects existing in
the database.

```
kubectl -n risingwave exec postgres-postgresql-0 -- \
  psql -h risingwave-frontend -p 4567 -U root -d dev \
  -c "SELECT name FROM rw_catalog.rw_sinks ORDER BY name;"
```

Swap `rw_sinks` for `rw_sources` or `rw_materialized_views`.

Two details that catch people: the frontend listens on **4567**, not RisingWave's default
4566; and the frontend container has no `psql` client, which is why this runs from the
postgres pod in the same namespace.

---

## Part 5 — Promoting to QA

QA does not move on a timer. A person moves it.

1. Go to the **chart repository** → **Actions** → **promote** → **Run workflow**.
2. Type `qa` in the **only** box.
3. Run it.

QA takes **the digest dev is currently running**, not the newest image in ECR. Nothing is
rebuilt between environments, so what QA runs is exactly what dev ran. That is what makes
dev a real gate rather than a label.

The QA promotion merges itself once it runs.

---

## Part 6 — Promoting to production

Same workflow, with `prod` in the **only** box.

Production takes **the digest QA is running**, and the workflow **opens a pull request rather
than merging it**. Someone else merges that pull request. This is deliberate.

A scheduled run carries no inputs, so the timer can only ever move dev. One tick can never
carry an image from ECR all the way to a production pull request.

---

## Troubleshooting

| Where | What you see | What it actually means |
|---|---|---|
| Build, OIDC step | `Not authorized to perform sts:AssumeRoleWithWebIdentity` | The repository or branch is not on the AWS trust list. Platform fixes it. The wording points at IAM permissions, but the cause is the claim not matching. |
| Build, first step | `Refuse to build an empty pipeline` | Nothing under `pipelines/`. Usually a path typo. |
| Apply job | `required runtime values are missing or empty: …` | Your SQL references variables nothing supplies. The message names them. Non-secret ones go in `config/dev.env`; ask platform for anything secret. |
| Apply job | Job is `Failed`, pods show `Error` | Read the pod log before it is garbage collected. The job itself is removed on success, so a job you can still see either failed or is running. |
| Argo CD | `Synced` and `Healthy`, but nothing changed | The promotion has not run yet. Check the chart repository for a recent `promote:` commit before looking anywhere else. |
| Argo CD | Application red, repository error | The deploy key for that repository is missing or wrong. Platform fixes it. |

---

## Reference

| Thing | Value |
|---|---|
| Pipeline repository | `usxpressinc/risingwave`, branch `master` |
| Build workflow | `.github/workflows/build-sql-image.yml` |
| Triggers on | pushes to `master` touching `pipelines/**` |
| Image repository | ECR, identified by digest, tagged with the commit SHA |
| Argo CD Application | `risingwave-etl` |
| Namespace (apply job) | `app-risingwave` |
| Namespace (RisingWave itself) | `risingwave` |
| Apply job | `etl-pipeline-apply` |
| Argo CD, dev | `argocd.op-dev.usxpress.io` |

---

## What is deliberately not automatic

| | Why |
|---|---|
| Branches do not build | Promotion takes the newest image in ECR. If branches built, any branch push would land on dev and dev would stop meaning anything. |
| QA needs a person | So that QA receives something dev has actually run. |
| Production needs two people | One to start it, one to merge the pull request. |
| The applier refuses empty values | It aborts rather than substituting a blank. A pipeline that writes nowhere while reporting success is worse than one that fails. |

---

## Glossary

**Digest** — a hash naming an image by its content. Unlike a tag, it cannot be repointed, so
"the digest QA is running" is an exact statement.

**Promotion** — copying a digest from one environment's values file to the next. No build, no
rebuild, no new image.

**Apply job** — the Kubernetes job that connects to RisingWave and runs your SQL files in
order. It is created by Argo CD and removed when it succeeds.

**Applier image** — the platform-maintained base containing `psql` and the apply script. Your
SQL is copied into it at build time, so a fix to the script reaches every pipeline on its
next build.

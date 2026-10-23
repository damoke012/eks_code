# RisingWave pipelines: change it, test it, ship it

**Who this is for:** anyone who writes or changes SQL in the RisingWave pipelines.
**What it covers:** one continuous path — your laptop, then dev, then QA, then production —
and where every variable lives along the way.
**Last verified:** 21 October 2026. Every timing on this page was measured on a real run.

---

## Start here

**One sentence:** you edit SQL on a branch, and the moment it merges to `master` it is on
dev by itself; QA and production each need a person.

Everything you need to open is in this table. Nothing else on this page asks you to find a
link.

| Where you need to get to | Link | What you do there |
|---|---|---|
| **The pipeline repository** | `github.com/usxpressinc/risingwave` | Edit SQL, open your pull request. Branch `master`. |
| **Your build** | same repo → **Actions** → **build-sql-image** | Watch the image build after you merge. ~1 minute. |
| **The chart repository** | `github.com/variant-inc/risingwave-pipeline` | Where the running version of each environment is recorded. You do not normally edit it. |
| **Promote to QA or production** | chart repo → **Actions** → **promote** → **Run workflow** | The only way QA or production move. |
| **Argo CD — dev** | `argocd.op-dev.usxpress.io` | See whether the cluster has picked your change up. App is `risingwave-etl`. |
| **Argo CD — QA** | `argocd.op-qa.usxpress.io` | Same, for QA. |
| **Argo CD — production** | `argocd.op-prod.usxpress.io` | Same, for production. |
| **RisingWave dashboard — dev** | `risingwave-dashboard.op-dev.usxpress.io` | The engine itself: streaming jobs, throughput, back-pressure. |
| **RisingWave console — dev** | `risingwave-console.op-dev.usxpress.io` | Browse the catalog — your sources, materialised views and sinks. |
| | `…op-qa…` / `…op-prod…` | The same two addresses exist for QA and production. |

**If you are in the office rather than on VPN** and these addresses do not load, that was a
cluster network policy and it was fixed on 20 October 2026. If it happens again, tell the
platform team — it is not your machine and not DNS.

### Who owns what

| | Owner |
|---|---|
| The SQL, and which variables the SQL needs | You |
| Whether a variable is secret | You decide, platform proposes |
| The value of a secret | Platform writes it. You never send one. |
| The build, the promotion, the cluster | Platform |

---

## The whole path at a glance

> **Insert the Lucid diagram here.**
> Import source lives in the repo at `wip/rw-deploy-doc/lucid-import.mmd`
> (in Lucid: **File → Import → Mermaid**).

Read the diagram as three different kinds of step:

- **Automatic** — happens with nobody watching: the build, dev's ten-minute promotion, Argo CD applying.
- **A person runs it** — the QA promotion, the production promotion.
- **A second person approves it** — the production pull request.

---

## Part 1 — Change it on your laptop

1. **Branch off master.**

   ```
   git checkout master && git pull
   git checkout -b your-change
   ```

2. **Edit the SQL.**

   | What | Where it goes |
   |---|---|
   | RisingWave SQL | `pipelines/<NNN-Entity>/*.rw` |
   | Postgres SQL | `pipelines/<NNN-Entity>/*.sql` |

   Files apply in **filename order**. That is what the number prefixes are for — `100-source`
   before `400-sink`.

3. **Run it locally** with the docker compose stack in the repository. This is the only place
   you can iterate in seconds, so it is worth doing properly before you push.

4. **Push and open a pull request.**

   ```
   git push -u origin your-change
   ```

   GitHub shows a banner on the repository page after a push. Otherwise: **Pull requests** →
   **New pull request** → base `master`, compare your branch → **Create pull request**.

5. **Squash and merge.**

**A branch push builds nothing.** Only `master` builds. Two reasons, and the second one is
absolute: dev always takes the newest image, so branch builds would mean any branch landing on
dev; and AWS only trusts `master`, so a branch build could not get credentials even if we
wanted it to.

> **To build without merging:** **Actions** → **build-sql-image** → **Run workflow**, on `master`.

---

## Part 2 — Variables: where each one lives

This is where most first deploys fail, so it is worth five minutes.

Your SQL refers to a variable by wrapping its name in percent signs — `%MONGODB_DATABASE%`.
Something has to supply a value for every one of those, in every environment. Where it comes
from depends on **two separate questions**, and they cross:

| | **Not secret** | **Secret** |
|---|---|---|
| **You own it** | `pipelines/config/dev.env`, `qa.env`, `prod.env` — in Git, your pull request | AWS Secrets Manager. You give platform the **key name**; they write the value once. |
| **Platform owns it** | In Git, platform's pull request | AWS Secrets Manager, platform writes the value |

Two rules fall out of that grid and save a lot of argument:

- **Who owns it** decides who raises the pull request.
- **Whether it is secret** decides the destination. "Platform owns it" never means we hold the
  value; "you own it" never means it goes in Git.

### Locally versus on-prem

| | On your laptop | On dev, QA and production |
|---|---|---|
| Non-secret values | your local `.env` for docker compose | `pipelines/config/<env>.env`, committed |
| Secrets | your own local credentials, never committed | AWS Secrets Manager, pulled into the cluster automatically and handed to the job as environment variables |
| Who wires it up | you | automatic, once the key exists |

The important part: **the variable name is identical in both places.** If your SQL says
`%MONGODB_CONNECTION_STRING%`, that is the name locally and the name in Secrets Manager. That
is the whole point of the percent-sign tokens — the same SQL file runs in both places.

### Three mistakes that cost real days

1. **Do not split a connection string into parts.** Use one variable holding the whole string.
   The on-prem MongoDB target is an Atlas `mongodb+srv` address, which **has no port at all** —
   so SQL referring to `%MONGODB_HOST%` and `%MONGODB_PORT%` can never be given a working
   value. This is exactly what stopped the pipeline on 21 October. One variable, whole string.
2. **Send key names, never values.** A credential pasted into Teams or email is in a system we
   do not control, and these credentials are usually shared copies — so one paste is everyone's
   problem, not just yours.
3. **`LIKE '%ABC%'` in your SQL will be read as a variable** called `ABC` and stop the run. Any
   capitalised word between percent signs is treated as a variable name. Write the pattern a
   different way.

### What happens if a value is missing

The apply job checks every variable your SQL asks for **before** it applies anything, and stops
if one is missing or empty:

```
ERROR: required runtime values are missing or empty: MONGODB_HOST, MONGODB_PASSWORD
```

That is the message you want. It names them. The alternative — substituting a blank, writing to
nowhere and reporting success — is what this check exists to prevent.

---

## Part 3 — How it reaches dev

Automatic. Roughly twenty minutes, and the only reason it is not two is a ten-minute timer.

| # | What happens | Notes |
|---|---|---|
| 1 | **The build starts** on your merge | **Actions → build-sql-image**, about a minute |
| 2 | It refuses an empty `pipelines/` directory | An image applying nothing would deploy green and do nothing |
| 3 | It takes a short-lived AWS session | Nothing is stored, so nothing can leak or expire |
| 4 | It builds the image — platform's applier base with your `pipelines/` copied in | You write no Dockerfile |
| 5 | It scans for critical vulnerabilities | A critical finding stops it while the image is still local |
| 6 | It pushes to ECR, named by **digest** | A digest names content, so nothing can be swapped underneath you |
| 7 | **A job runs every ten minutes**, takes the newest image, and writes that digest into `values-dev.yaml` | You will see a commit reading `promote: dev to sha256:…` |
| 8 | **Argo CD sees the commit** and replaces the apply job | The digest changed, so the job changed; Kubernetes cannot edit a job in place, so Argo deletes and recreates it. **This is also why a previously failed job never blocks the next attempt.** |
| 9 | **The job runs your SQL** — loads `config/dev.env`, checks the values, applies in filename order | |
| 10 | **The job deletes itself on success**, and the log goes with it | If you want the log, read it while the pod still exists |

**Measured 21 October 2026**

| Event | Time (UTC) |
|---|---|
| Merged to `master` | 23:24 |
| Image in ECR | 23:24:53 |
| Promotion wrote the digest | 23:36:22 |
| Apply job finished | 13 seconds after it started |

---

## Part 4 — Prove it actually worked

A green job means the script exited zero. What proves your change is **the objects existing in
the database.** Easiest check is the console — `risingwave-console.op-dev.usxpress.io` — which
lists sources, materialised views and sinks.

If you prefer the command line:

```
kubectl -n risingwave exec postgres-postgresql-0 -- \
  psql -h risingwave-frontend -p 4567 -U root -d dev \
  -c "SELECT name FROM rw_catalog.rw_sinks ORDER BY name;"
```

Swap `rw_sinks` for `rw_sources` or `rw_materialized_views`.

Two details that catch everyone: the frontend listens on **4567**, not RisingWave's documented
4566; and the frontend container has no `psql`, which is why this runs from the postgres pod
next door. The database is called `dev` **in every environment** — it is not the environment
name.

---

## Part 5 — Promote to QA

QA does not move on a timer. A person moves it.

1. Chart repository → **Actions** → **promote** → **Run workflow**
2. Type `qa` in the **only** box
3. Run it

QA takes **the digest dev is currently running** — not the newest image in ECR. Nothing is
rebuilt between environments, so QA runs exactly the bytes dev ran. That is what makes dev a
real gate rather than a label.

The QA promotion merges itself once it runs. Then check `argocd.op-qa.usxpress.io` and the QA
console, the same way you checked dev.

---

## Part 6 — Promote to production

Same workflow, with `prod` in the **only** box.

Production takes **the digest QA is running**, and the workflow **opens a pull request instead
of merging it.** Somebody else merges that pull request — two people, deliberately.

The timer can only ever move dev: a scheduled run carries no inputs. One tick can never carry
an image from ECR all the way to a production pull request.

---

## When something goes wrong

| Where | What you see | What it actually means |
|---|---|---|
| Apply job | `required runtime values are missing or empty: …` | Your SQL asks for variables nothing supplies. The message names them. Non-secret ones go in `config/<env>.env`; ask platform for anything secret. |
| Apply job | Job `Failed`, pod shows `Error` | Read the pod log now. A successful job deletes itself, so a job you can still see either failed or is still running. |
| Argo CD | `Synced` and `Healthy`, but nothing changed | The promotion has not run yet. Look for a recent `promote:` commit in the chart repository before looking anywhere else. |
| Argo CD | Application red, repository error | A deploy key is missing or wrong. Platform fixes it. |
| Build, OIDC step | `Not authorized to perform sts:AssumeRoleWithWebIdentity` | The repository or branch is not on the AWS trust list. Platform fixes it. The wording blames permissions; the cause is the branch. |
| Build, first step | `Refuse to build an empty pipeline` | Nothing under `pipelines/`. Usually a path typo. |
| Browser | The dev or QA address does not load from the office | Cluster network policy, fixed 20 October 2026. Tell platform if it returns. |

---

## What is deliberately not automatic

A plainly honest list — each of these is slower on purpose.

| | Why |
|---|---|
| Branches do not build | Dev takes the newest image, so branch builds would mean every branch push landing on dev |
| QA needs a person | So QA receives something dev has actually run |
| Production needs two | One to start it, one to merge the pull request |
| The applier refuses an empty value | It stops rather than substituting a blank. A pipeline that writes nowhere while reporting success is worse than one that fails. |

---

## Reference

| Thing | Value |
|---|---|
| Pipeline repository | `usxpressinc/risingwave`, branch `master` |
| Chart repository | `variant-inc/risingwave-pipeline`, chart at `deploy/chart` |
| Build workflow | `.github/workflows/build-sql-image.yml` |
| Builds on | pushes to `master` touching `pipelines/**` |
| Image | ECR, named by digest, tagged with the commit SHA |
| Argo CD application | `risingwave-etl` |
| Namespace — apply job | `app-risingwave` |
| Namespace — RisingWave | `risingwave` |
| Apply job | `etl-pipeline-apply` |
| Database name, every environment | `dev` |
| RisingWave frontend port | 4567 |

---

## Words used on this page

**Digest** — a hash naming an image by its content. Unlike a tag it cannot be repointed, so
"the digest QA is running" is an exact statement about exact bytes.

**Promotion** — copying a digest from one environment's values file to the next. No build, no
rebuild, no new image.

**Apply job** — the Kubernetes job that connects to RisingWave and runs your SQL files in
order. Argo CD creates it; it removes itself when it succeeds.

**Applier image** — the platform-maintained base holding `psql` and the apply script. Your SQL
is copied into it at build time, so a fix to the script reaches every pipeline on its next
build.

**Secrets Manager** — where AWS holds credentials. The cluster pulls them in and hands them to
your job as environment variables. You never see a value and never put one in Git.

---

## Next

| You want to | Do this |
|---|---|
| Add a pipeline | Part 1, then send platform the **key names** your SQL needs and which are secret |
| Get your change to QA | Part 5 — you can run it yourself |
| Get your change to production | Part 6, then ask someone to merge the pull request |
| Report something broken | Platform team, with the Argo CD application name and the pod log |

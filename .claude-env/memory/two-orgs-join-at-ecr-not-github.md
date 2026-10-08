---
name: two-orgs-join-at-ecr-not-github
description: "USX app teams consume PUBLISHED reusable workflows and never hand over repo keys; our app-template violated both. Join the two GitHub orgs at ECR via OIDC, not with a cross-org token, and the repo-location question disappears"
metadata:
  node_type: memory
  type: project
---

**2026-10-07 call** (Steve, Tim, Idris, Pujit, Doke). The question on the table was *which
GitHub org the RisingWave pipeline repo should live in*. It is the wrong question and it
cost three weeks.

**Tim stated a USX standard, not a preference:** *"We have not been developing GitHub
Actions, and we have not been custom curating our deployment from scratch. We have used
actions that have come out of the variant space… you just create it and then you publish it
and then it gets used."* And: *"We've never done those repo keys and passing things
around."*

`wip/onprem-app-cicd/app-template/.github/workflows/build-and-push.yml` breaks both — a
90-line workflow the app team copies and then owns, whose promotion job needs a cross-org
token. **Right content, wrong packaging.** Keep it as the reference implementation; stop
shipping it as the interface.

**The platform needs exactly one thing from an app repo: an image in ECR.** That is an AWS
boundary, so it does not care which GitHub org the source sits in. Design in
`wip/onprem-app-cicd/cross-org/` (all three workflows parse):

- **Reusable workflow** `variant-inc/usx-cicd-workflows/.github/workflows/app-build-push.yml@v1`;
  the app's own file is 44 lines with two values and **no secrets**.
- **OIDC only.** A reusable workflow runs in the *caller's* secret context, so a variant-inc
  org secret is invisible to it anyway — which forces the clean answer. Revoking access =
  deleting a line of Terraform.
- **The promotion PR is opened on the platform side** (`promote-from-ecr.yml`, polls ECR),
  because the overlays live there. So the app repo needs no write access to ours, and Argo CD
  never reads theirs.

**How to apply:** when two orgs must cooperate, look for a boundary you already control that
is not GitHub. Credential exchange was the problem; ECR made it unnecessary.

✅ **MEASURED 2026-10-07.** `PUT /repos/variant-inc/usx-cicd-workflows/actions/permissions/access
-f access_level=enterprise` **stuck**, so the two orgs share one GitHub enterprise and a
`usxpressinc` repo CAN call a *private* `variant-inc` reusable workflow. No public fallback
needed.

⚠️ **"Neither of us have permission to your repo" (said on the call) is FALSE.**
`gh api /repos/usxpressinc/risingwave-poc --jq .permissions` → `push: true` for `dare-x`.
The credential gap that produced the clone-our-repo workaround, which produced the whole
org debate, does not exist in that direction. Still PR rather than push — it is Tim's repo
— but never repeat the access claim without running that one line.

⚠️ **`usxpressinc/risingwave-poc` defaults to `master`, not `main`.** The OIDC `sub` is a
literal match; a policy written for `main` fails as *"Not authorized to perform
sts:AssumeRoleWithWebIdentity"* and sends you to IAM instead of to the branch name.

⚠️ **Still unverified:** the exact app-repo name.

**The two orgs are `variant-inc` and `usxpressinc`** (confirmed 2026-10-07, `gh api /user/orgs`). The call transcript's "Usxsqlopsprd" was a mis-transcription and is not an org.

⚠️ **The OIDC `sub` is org-qualified.** A repo transferred between orgs stops authenticating
at once, nothing changed on its side, and the error names permissions rather than the claim.
Related: [[gha-oidc-needs-environment-claim]] — pinning `environment:` in the sub requires
the calling job to declare it, so our policy pins repo + ref instead.

**Tim is not blocked on the org decision.** He is blocked on a local Docker
container-user/file-ownership mismatch and is days into it alone.

Related: [[onprem-app-cicd]], [[usx-github-enterprise-not-personal]],
[[two-gha-roles-one-pipeline-repo]], [[adjacent-step-green-signals]] (a promotion poll that
finds nothing still reports success).
Note: `wip/onprem-app-cicd/cross-org/FINDINGS-2026-10-07-two-orgs-one-pipeline.md`.


## 2026-10-07 — proven, then blocked on one setting

**The design is sound and the failure is access.** A six-line no-op reusable workflow fails
identically to the real one, so content was never implicated; `actionlint 1.7.7` passes both
files.

⚠️ **`actions/permissions/access` is INERT on a private repo.** `enterprise` and
`organization` are both accepted by the PUT, persisted, and read back — and neither grants
anything. The source repo must be **internal** or **public**. I reported the successful PUT
as "the deciding check passed"; it was a true statement about a stored setting and said
nothing about the capability. The proof is a run.

⚠️ **`gh workflow run` is the fast diagnostic.** A dispatch on a caller whose `uses:` cannot
resolve returns **HTTP 422 with the literal parse error**. The same file triggered by push
gives a failure with **no job, no log**, and only a generic "workflow file issue" in the UI —
so `gh run view --log-failed` says "log not found" and `/jobs` returns empty. Neither absence
is a finding.

⚠️ **"Workflow was not found" means "you cannot see it" as often as "it does not exist".**

**Blocked on:** an org owner making `variant-inc/usx-cicd-workflows` internal. `dare-x`
created the repo and still gets 422 "Visibility can't be changed by this user".

⚠️ **Three things today ended at a permission Doke does not hold** — both orgs' Actions
policies (403) and repo visibility (422). He owns the delivery path without being an owner
in either org hosting it. Raise as its own item.

Note: `wip/onprem-app-cicd/cross-org/FINDINGS-2026-10-07-two-orgs-one-pipeline.md`.


## ✅ 2026-10-07 — PROVEN on variant-inc/risingwave-pipeline

A 15-line caller with **no secrets** built and pushed to ECR. Two green runs, two new
digests (`3e91003f` 17:07, `c3f76243` 17:09, against `b687e6c5` from 29 Sep). Assumed
`arn:aws:sts::064859874041:assumed-role/gha-risingwave-etl-ecr-push/gha-variant-inc-<run_id>`.
The reusable workflow lives in **`variant-inc/iaac-risingwave-cicd`** (internal), tag `v1`.

### ⚠️ THE RULE — two conditions, neither sufficient, ONE error message

| | |
|---|---|
| Visibility | `internal` or `public`. **Private cannot share**, whatever `access_level` says |
| `actions/permissions/access` | `organization` or `enterprise`. **Defaults to `none`** on every repo |

`access_level` is **per repository and does not travel.** I set it on the first host, moved
the workflow to a second host, and never set it there — that one oversight cost more than
every other dead end. All failure modes, plus a genuinely absent file, emit the identical
`workflow was not found`.

### Method that worked

- **`gh workflow run` is the diagnostic.** An unresolvable `uses:` returns **422 with the
  literal parse error** in a second. The same file on push gives a failure with no job, no
  log, and a generic "workflow file issue". A **404** from the dispatch means only "not
  indexed yet" — retry; do not read it as blocked.
- **Bisect with a six-line no-op.** `ping.yml` failing identically retired the entire
  content hypothesis in one commit.
- **`actionlint` for schema; a run for reachability.** `yaml.safe_load` proves neither.
- **`gh run view --log` returns ZERO lines for a reusable-workflow run.** Use
  `gh api /repos/<o>/<r>/actions/jobs/<job_id>/logs`.

⚠️ **`variant-inc/actions-collection` is PUBLIC and already ships `build-push-image`.**
Shared actions live in `variant-inc/actions-*` — that is what Tim meant by "actions that
come out of the variant space". I wrote one from scratch without looking, and created a
private `usx-cicd-workflows` that is now an orphan to delete. **Look for the existing
convention before publishing a new one.**


## ✅ 2026-10-07 — the build path is DELIVERED, the deploy half is not

**What exists.** `variant-inc/iaac-risingwave-cicd` (INTERNAL, `access_level: enterprise`,
tag `v1`) publishes three workflows: `app-build-push.yml` (repos with a Dockerfile),
`sql-pipeline-build-push.yml` (repos with only SQL), and `publish-applier.yml`. ECR
`risingwave/sql-applier` holds the applier base `sha256:0a13bc0d…`; `risingwave/poc-pipeline`
is created and empty. Roles `gha-sql-applier-ecr-push` and `gha-risingwave-poc-ecr-push`
trust `…:main` and `…:master` respectively. `usxpressinc/risingwave-poc#5` is open.

**An app repo with only SQL needs no Dockerfile.** The applier tooling is published once as
a base image; the reusable workflow generates a two-line image `FROM` it at build time. A
fix to `apply.sh` then reaches every consumer on their next build instead of a PR per repo.
The workflow **refuses to build when the SQL dir is empty** — an image that applies nothing
deploys green.

⛔ **The deploy half is unproven.** `usxpress-app` renders and lints and has **never been
applied to a cluster**; nothing consumes `risingwave/poc-pipeline`. The chain stops at
"image in ECR".

⚠️ **The SQL is duplicated and has DRIFTED.** `variant-inc/risingwave-pipeline` has 4 SQL
files, `usxpressinc/risingwave-poc` has 3 — ours carries `pipelines/Brand/300-transform.sql`.
**QA runs a transform absent from the source of truth.** Decide which is right before the
cutover. Named in PR #5.

⚠️ **Three IAM roles are hand-made and untagged** in 064859874041 (plus the pre-existing
`gha-risingwave-etl-ecr-push`, whose description says `main` while its policy pins `master`).
`gha-oidc-trust.tf` must IMPORT them — a second declaration of a live role is how a destroy
removes the real one. See [[two-projects-one-resource]].

**Read the house action before writing your own.** `variant-inc/actions-collection` is public
and ships `build-push-image`. Two things came from reading it: `TRIVY_DB_REPOSITORY:
public.ecr.aws/aquasecurity/trivy-db:2` (the default DB is on ghcr.io and gets rate-limited)
and severity `CRITICAL` (being stricter than every other app invites "why is mine different").
Not copied: it pins `aquasecurity/trivy-action@master`, a floating third-party ref, in the
action every app uses.

⚠️ `iaac-risingwave-cicd` has **2 critical Dependabot alerts** and is now load-bearing, and
its open Renovate branch **deletes `publish-applier.yml`** — rebase, never merge.

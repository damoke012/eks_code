---
name: risingwave-canonical-repo
description: PROVEN END TO END 2026-10-21 — push to running sinks in ~20 min, no human step. DECIDED 2026-10-21 — usxpressinc/risingwave is THE RisingWave pipeline repo going forward; risingwave-poc and variant-inc/risingwave-pipeline are legacy. Default branch is master, which the OIDC trust matches literally
metadata:
  type: project
---

✅ **PROVEN END TO END the same day.** Tim pushed at 23:24 UTC; `sha256:db42b04b…` reached
ECR immediately, `promote.yml` pinned it at 23:36, Argo synced, the applier Job completed in
13s, and `rw_catalog.rw_sinks` holds `brand_sink_mongo` and `employees_sink_mongo`.
**About 20 minutes, no human step.** Detail: `wip/rw-new-repo-cutover/`.

**Tim Preble created `usxpressinc/risingwave` on 2026-10-21 and the team uses it from now
on.** Measured the same day: default branch **`master`**, visibility **INTERNAL**, and it
carries `.variant`, `.github`, `docker/`, `pipelines/` (with `config/dev.env` and
`config/qa.env`), `pipeline-manager.ps1` and `PIPELINE_GENERATOR_GUIDE.md`.

**There are now THREE repos and only one is canonical:**

| Repo | Status |
|---|---|
| **`usxpressinc/risingwave`** | ✅ canonical from 2026-10-21 |
| `usxpressinc/risingwave-poc` | legacy — but it is what BUILDS today (ECR `risingwave/poc-pipeline` → op-dev via Argo CD), proven 2026-10-09 |
| `variant-inc/risingwave-pipeline` | legacy fork — **`master` holds ONE sql file** (`shared/scripts/db-init/100-helpers.sql`). Its real SQL lives on BRANCHES (`f/driver`), never on master |

**Why:** nothing points at the new repo yet. Tim asked "can you hook up CI/CD" and that is
not a switch — the delivery chain is pinned to the old repo at the IAM layer.

**How to apply — three things, in this order:**
1. ✅ **DONE 2026-10-21 — and the build is GREEN from the new repo.** It took THREE
   subjects, not one: the new repo emits an **immutable** OIDC subject
   `repo:usxpressinc@101195652/risingwave@1428674918:ref:refs/heads/master`, so the plain
   `repo:org/name` form could never match and the failure read as an IAM authorisation error.
   See [[github-immutable-oidc-subject]]. `cloudops` was given write on the repo the same
   evening, after a `gh workflow run` 404'd.

   `gha-risingwave-poc-ecr-push` in account **064859874041**
   (profile **`infra-common`**) now trusts BOTH repos — its `sub` condition is a two-element
   list, `repo:usxpressinc/risingwave:ref:refs/heads/master` and the `-poc` one. Added, not
   replaced, so existing builds keep working. The role is still hand-made and untagged;
   `gha-oidc-trust.tf` must import it before anything declares it.

   The sub is matched as a literal string, so
   `repo:usxpressinc/risingwave:ref:refs/heads/master` must be added. A new repo otherwise
   fails as *"Not authorized to perform sts:AssumeRoleWithWebIdentity"*, which reads as an
   IAM permissions problem rather than a repo-name mismatch. **Both repos end in `master`,
   so the ref half is unchanged** — only the repo name differs.
   See [[two-orgs-join-at-ecr-not-github]], [[gha-oidc-needs-environment-claim]].
2. **Workflow** calling the published `variant-inc/iaac-risingwave-cicd@v1`
   (`sql-pipeline-build-push.yml`). INTERNAL visibility is fine — the two orgs share one
   GitHub enterprise and `access_level=enterprise` was proven on 2026-10-07.
3. **ECR** — reuse `risingwave/poc-pipeline` or cut a new repository, and decide whether the
   old repo stops building. Two repos pushing one image tag is how a rollback resurrects.

## ✅ MEASURED 2026-10-21 at `89b2cd1` — the two repos differ by ONE file

Counting **both `.rw` and `.sql`** (the repo's own README: each `NNN-Entity` folder is "a set
of .rw (RisingWave) and .sql (Postgres)"):

| | POC | NEW |
|---|---|---|
| pipeline files | 24 | 23 |
| difference | `pipelines/100-Brand/001-prescript.sql` — **POC only** | |

`100-Brand`, `200-ActiveResource`, `300-Employee`, `Template` and `shared/scripts/db-init`
are otherwise byte-for-byte the same file list. Brand and ActiveResource ARE in the new repo.

⛔ **My first two inventories were wrong because `find -name '*.sql'` measured ONE of the two
extensions**, and the pipelines are nearly all `.rw`. It produced a confident "Brand isn't in
the new repo", twice, and nearly sent that to Tim. **Check what file types a repo actually
uses before filtering on one.** A new instance of [[proxy-is-not-the-property]].

⚠️ **`.github/workflows/build-sql-image.yml` in the new repo reads:**

    uses: variant-inc/iaac-risingwave-cicd/.github/workflows/sql-pipeline-build-push.yml@v1
    ecr_repository: risingwave/poc-pipeline

**It publishes to the SAME ECR repository the POC publishes to — the one op-dev pulls.** The
CI/CD is already written; the only missing piece is the IAM OIDC trust for
`repo:usxpressinc/risingwave:ref:refs/heads/master`. Tim confirmed 2026-10-21: the new repo
takes over and he is clear to deploy to dev. **Disable the POC's workflow at the same time**,
or two repos publish into one image repository and the last push wins.

⚠️ **Tim's commit `89b2cd1` is called "remove poc".** Brand's prescript exists only in
`risingwave-poc`; that repo must not be archived until the one missing file is resolved.

⚠️ `pipelines/config/*.env` values are secrets-adjacent — print key names only, never values.
And the shipped `apply.sh` has NO placeholder validation: an unset var aborts, an **EMPTY**
one substitutes silently and records green ([[empty-value-renders-as-empty-string]]).

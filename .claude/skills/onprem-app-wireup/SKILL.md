---
name: onprem-app-wireup
description: Wire an application's container image into an on-prem Argo CD environment, or find why one that "deployed" is doing nothing — a green pipeline with no data, ImagePullBackOff or a 403 on an ECR manifest HEAD, "the sync hook succeeded but the tables are empty", a developer pushing to a repo nothing deploys from, ExternalSecret green while the value is unusable, a missing-runtime-values error naming systems you do not have, or Argo never triggering after an app repo merge. Nine gates in a relay, each failing green.
---

# Wiring an app image into an on-prem environment

Delivery from an app repo to an on-prem Argo CD cluster is a **relay**: nine handoffs, each
owned by a different system. Measured on `op-usxpress-dev` 2026-10-09, **every single one was
broken, and every one reported success.** Eight green ticks and zero rows.

That is the trap this skill exists for. **Judge the relay at the destination — rows in the
target — and never at a status field.** Then walk the gates in order; each one's symptom
mimics the next one's cause.

## Walk the gates in order

Stop at the first gate that fails. A later gate's symptom is meaningless while an earlier one
is red, and each fix is cheap once you know which gate you are at.

### 1. Is the developer pushing to a repo that deploys?

A forked or ancestor copy of a repo builds nothing and still shows a green tick, from a
leftover workflow. Settle it by content, not by name:

```
git ls-remote --heads https://github.com/<org>/<repo>.git
gh run list --repo <org>/<repo> --limit 10
```

Read the **WORKFLOW column**, not the status. A tick from a workflow unrelated to delivery
(an old Octopus push, a dependency graph) is noise. Compare the two candidate repos'
workflow counts and the presence of the build file.

### 2. Does the app repo call the published build workflow?

The app repo needs one small caller file; the reusable workflow lives on the platform side so
the app holds no credential. `gh pr list` on the app repo often shows it **open and
unmerged** — that was the whole blocker for three weeks.

```
gh pr list --repo <org>/<app-repo> --state open
gh api "repos/<org>/<app-repo>/contents/.github/workflows" --jq '.[].name'
```

Two conditions gate a cross-org reusable workflow, **neither sufficient alone, one error
message**: the source repo must be `internal` or `public` (private cannot share), and
`actions/permissions/access` must be `organization` or `enterprise`. `access_level` is **per
repository and does not travel**. Every failure, including a genuinely absent file, emits the
identical `workflow was not found`.

### 3. Did an image actually reach the registry?

A green build is not an image. Read the digest from the job log, then confirm it at the
registry:

```
aws ecr describe-images --profile <p> --region <r> --repository-name <repo> \
  --image-ids imageDigest=<digest> --query 'imageDetails[0].imagePushedAt'
```

`gh run view --log` **sometimes returns zero lines and zero stderr** — seen on a
reusable-workflow run, and again on a plain `workflow_dispatch` run (2026-10-09). `--log-failed`
printed nothing for the same run while the job held 1079 lines. An empty log is NOT MEASURED,
never evidence; use `gh api /repos/<o>/<r>/actions/jobs/<job_id>/logs`. The digest appears as
`"containerimage.digest"`; the concatenated `repo@sha256:…` form is often never printed.

**A re-run cannot rebuild an unchanged commit.** Where the repository is tag-immutable and the
build tags by commit SHA, dispatching the same ref fails at the push step with `tag invalid:
… cannot be overwritten because the tag is immutable` — after the build, the scan, the OIDC
assume and the ECR login have all passed, so it reads like a permissions regression and is not
one. The consequence that bites: **moving a base image's tag can never reach an unchanged
source commit.** Publishing a fixed `…/sql-applier:latest` changes nothing for a consumer whose
`FROM` resolves it at build time, because there is no new build to run. Treat
"merge, republish the base" as two thirds of a rollout; the third part is a new commit in the
consuming repo, and **both halves are needed**:

```
git commit --allow-empty -m "chore: rebuild on <the fixed base>" && git push origin master
gh workflow run <build workflow> --repo <org>/<repo> --ref master
```

The commit frees the immutable tag; the dispatch is what actually builds, because a build
filtered on `paths:` ignores a commit that changes no files and creates **no run at all** —
indistinguishable from a build that has not started. Check that a run exists for the new SHA
before concluding anything about it ([[immutable-tag-blocks-base-image-rebuild]]).

### 4. Can the cluster pull it?

**A new ECR repository has NO repository policy**, so a cross-account on-prem pull fails
`403 Forbidden` on the manifest HEAD. The repository that works carries a policy the new one
does not. See [[ecr-repo-policy-is-per-repository]] for the four error messages and which
fix each one means.

```
aws ecr get-repository-policy --profile <p> --region <r> --repository-name <works> \
  --query policyText --output text
aws ecr get-repository-policy --profile <p> --region <r> --repository-name <new> \
  --query policyText --output text || echo "NO POLICY on the new repo"
```

Suspect the repository policy before the pull credential. **A pull Secret's
`creationTimestamp` is not the age of its data** — a refresher CronJob updates data in place,
so a seven-week-old Secret can hold a fresh token. Check for the refresher first:
`kubectl get cronjobs -A | grep -i ecr`.

### 5. Does anything copy the digest into the environment's values?

**This is the gate people forget, because nothing reports it.** The app repo pushes an image;
Argo CD watches the platform repo. Without a step that writes the new digest into the
environment's values file, Argo is correct to do nothing and everything upstream is green.

The fix is a workflow on the platform side that polls the registry and opens the promotion PR
**there**, so the app repo needs no write access. Pattern and guards:
`wip/onprem-app-cicd/promotion/promote.yml`.

Two values change together, not one: **`image.repository`** (a different app means a
different registry repository) and `image.digest`. Updating only the digest points the
environment at a digest that does not exist in the repository it names.

⚠️ A `*/10` cron is the mechanism, not the guarantee. GitHub schedules run late routinely.
Dispatch it rather than waiting, and never diagnose from a cron that has not fired yet.

### 6. Are the runtime values wired — not merely present?

The usual finding is **not** that credentials are missing from the secret store. They are
there and were never connected. Enumerate both ends before concluding anything is absent:

```
aws secretsmanager list-secrets --profile <p> --region <r> \
  --query "SecretList[?starts_with(Name, '<prefix>/')].Name" --output text | tr '\t' '\n'
aws secretsmanager get-secret-value --profile <p> --region <r> --secret-id <id> \
  --query SecretString --output text | jq -r 'keys[]'
```

The second command prints **key names only** — values go to `jq`, never to the screen.

Then check the shape, not the presence. A connection string and a host+port pair are not
interchangeable, and the gap reads as a missing credential:
[[risingwave-mongodb-sink-facts]].

Count the keys the environment actually received. ESO writes a **partial** secret on error,
so the pod dies at container creation with `RESTARTS 0` — invisible to restart alerts:

```
kubectl --kubeconfig=<kc> -n <ns> get secret <name> -o json | jq -r '.data | keys | length'
```

### 7. Do the exclusion patterns match the real paths?

A validator error naming dozens of variables for systems you do not have is usually **an
exclusion regex that matches nothing**. Ours named `Brand/` and lowercase `employee` while
the tree was `100-Brand/` and `300-Employee/` — numeric prefixes and a capital letter. Every
exclusion matched zero files, so every file was discovered and every variable required.

Print the applier's own `exclude` lines and count them against the tree before supplying a
single value. Suspect the pattern before the system
([[validator-checks-every-value-not-the-selected-ones]], [[a-guard-can-measure-the-wrong-thing]]).

### 8. Do the systems the SQL reads from exist?

A pipeline can be delivered perfectly and still have nothing to read. Separate **"the
credential is missing"** from **"the system was never built"**
([[missing-credential-may-mean-missing-system]]). For a CDC source that means a database, a
role with `REPLICATION`, a schema, a publication, and `wal_level=logical` plus a restart.

A hardcoded `\c <db>` inside an applied `.sql` file **overrides the configured database**, so
the name is fixed in the developer's SQL and the variable is decorative. Grep for it before
choosing a name: `grep -rnE '\\connect|\\c [a-z]' <pipeline dir>/`. More in
[[psql-c-does-not-interpolate]].

### 9. Is the consumer authorised, and is the destination reachable?

The last gate is the one that produces a green deploy and an empty table. A topic-level or
consumer-group grant is a separate deployment in a separate repo, often gated by someone
else's approval ([[a-declared-grant-is-not-the-literal-acl]],
[[octopus-deploy-can-gate-the-pr]]). A zero row count has at least four indistinguishable
causes; `scripts/rw-diagnose-empty-mv.sh` names which.

## Prove the credential before judging anything

An open port is not an authenticated session, and `2>/dev/null` turns an auth failure into
an empty string that reads exactly like absence. On 2026-10-09 the companion check reported
`FAIL digest` and `FAIL secret` for QA while both objects were present and healthy — the
kubeconfig's `aws-iam-authenticator` profile had an expired SSO session. Two gates' worth of
invented findings sent the investigation down a conclusion ("QA is still on the kustomize
overlay") that was flatly wrong; QA had been on the chart all along.

The kubeconfig pins its own profile in the exec env, so logging into a *different* profile for
the same account changes nothing:

```
grep -A12 'exec:' <kubeconfig> | grep -E 'command|AWS_PROFILE|value:'
aws sso login --profile <that exact profile>
kubectl --kubeconfig=<kubeconfig> get --raw /version
```

Until that last command succeeds, every finding is NOT MEASURED, including the reassuring ones.

## Done means rows at the destination

Not a green sync, not a succeeded hook, not an `ExternalSecret` reporting `SecretSynced`.

`scripts/onprem-app-wireup-check.sh <env>` walks gates 3 to 6 read-only and prints
PASS/FAIL/NOT-MEASURED per gate. Run it before and after any wire-up, and on the next
environment before assuming parity.

Two specific proofs worth insisting on, because both have been faked by a true-but-adjacent
signal:

* **A row count cannot prove an apply ran.** Drop-and-recreate SQL rebuilds to the *same*
  numbers from the same source. Use an object the new code **renames** — if it exists, the
  new code ran. That is what settled it here.
* **Argo deletes a sync-hook Job on success as well as failure**, so `kubectl logs job/...`
  returns `NotFound` either way. The durable record is
  `.status.operationState.syncResult.resources`. To read a failure, re-run the **same
  digest** as a plain Job under its own name ([[hook-job-failure-destroys-its-own-log]]).

## Promote with one digest, and let dev be a real gate

Each environment's source is the environment before it: registry → dev → QA → prod. QA can
then only receive something dev has actually run, and nothing is rebuilt between
environments. dev and QA may self-merge — a promotion PR nobody is watching is a drawer, and
one sat open four weeks while QA ran a stale image. **Prod opens a PR and waits for a
person.**

Which environments are live belongs in a data file (`apps.json`), never in the workflow, so a
new environment is opt-in and merging the machinery changes nothing. Guards that earn their
place: the target values file must already name the app's own registry repository, and the
edit is grepped back after the `sed`.

## Why this exists

Nine gates, nine green ticks, zero rows, and three weeks. The work was never hard once the
gate was identified — it was finding which of nine silent handoffs had failed. Full account:
`wip/onprem-app-cicd/STATE.md` and `wip/onprem-app-cicd/RUNBOOK-app-wireup.md`.

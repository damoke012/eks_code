# Review: On-Prem Application Onboarding Guide (Idris)
2026-10-19 — reviewed as the standard for ALL applications, not just the next one

## What is strong, and should not be lost in editing

- **The status column on the four classes.** "Proven / Unproven / Designed / Untested" is the
  most valuable line in the document. Most onboarding guides describe an aspiration as if it
  were a system. This one says which paths have carried a real app and which have not.
- **The red-flag glossary.** This is accumulated scar tissue and it is exactly the right form:
  the symptom, why it is bad, the fix. Additions suggested at the end.
- **"What Is Not Ready" with ticket numbers.** Honest, and it makes the gaps assignable.
- **Flux owns the platform, Argo owns `app-*`, they must never overlap.** A clear boundary
  stated once, early.
- **The OIDC provider data-source-not-resource warning.** Correct, and it prevents a failure
  that takes out federation for a whole account.

## ⛔ Three factual errors

### 1. Section 5b sends prod to a decommissioned branch
> "Repo: iaac-talos-flux-platform (branch: op-dev for dev, op-qa for QA, **dpl2 for prod**)"

Section 15 lists **dpl2 as decommissioned** (INFRA-1686) and the branch mapping table in the
same section says prod is **op-prod**. The document contradicts itself, and 5b is the half
someone follows because it appears first and in the step-by-step. Fix 5b to `op-prod`.

### 2. The ECR account and region look wrong
The guide gives ECR account IDs **per environment** (dev 700736442855, qa 527101283767,
prod 937464026810) and states **ECR region us-east-1**.

Measured 2026-10-19, the images on-prem actually pulls:

    arn:aws:ecr:us-east-2:064859874041:repository/risingwave/poc-pipeline
    arn:aws:ecr:us-east-2:064859874041:repository/risingwave/sql-applier
    arn:aws:ecr:us-east-2:064859874041:repository/risingwave/etl-pipeline

That is **account 064859874041 (Infrastructure-Common), region us-east-2** — a shared registry,
not a per-environment one. This matters more than a typo: cross-account pulls need a
**repository policy**, and a NEW ECR repository has none, so the first pull 403s on the
manifest HEAD. An app team following the per-env table will create a repo in the wrong account
and hit an error that reads like a credential problem.

Worth confirming whether per-env ECR also exists; if both are real, say which is for what.
Same question for the Secrets Manager region — the guide says us-east-1 and I have not
measured it, so flag rather than assert.

### 3. The validation checklist's secret check cannot detect the failure it is for
> "All secrets show **SecretSynced** status"

A green `ExternalSecret` proves the **sync ran**, not that the content is usable. ESO writes a
**partial** secret on error: the keys it could resolve are written, the status goes
`SecretSyncedError`, and anything consuming the empty key dies at container creation with
`RESTARTS 0` — invisible to restart alerts. This has bitten us twice (Wiz, QA etcd-backup).

Replace with: count the keys and assert none is empty.

    kubectl -n app-<APP> get secret <NAME> -o json \
      | jq -r '.data | to_entries[] | select(.value=="" or .value==null) | .key'

Empty output is the pass. "Synced" is not.

## Gaps that matter because this is for EVERY app

### A. Nothing copies the image digest into the values file
The guide says "pin image digests (not just tags)" — correct — but never says **what updates
the digest when a new image is built**. This is the gate nobody looks for: the app pushes an
image, Argo watches a repo nobody changed, and every status is green with nothing deployed.

The working pattern is a promotion workflow on the **platform** side that polls the registry
and opens the PR there, so the app repo needs no write access to platform repos. Registry →
dev → QA → prod on ONE digest, prod opening a PR that waits for a person. It exists and runs
(`risingwave-pipeline/.github/workflows/promote.yml`, driven by an `apps.json` opt-in list).
An onboarding guide without this step produces apps that deploy once and never again.

### B. No contract for the config and secret keys an app needs
Nothing in the guide says how an app declares the variables it consumes, what happens when a
new one appears, or who decides whether it is secret.

Today, for RisingWave, a developer adding a new placeholder breaks the environment: the applier
expands an unset variable under `set -u` and the whole sync dies before anything applies. The
inverse is worse — an **empty** value substitutes silently and records success.

The proposed shape (`DESIGN-variable-contract-2026-10-19.md`): the developer declares each
variable **next to the code that needs it**, with `sensitive: true|false`. Non-secret goes to
the env values file; secret goes to Terraform → Secrets Manager → ESO. The human gate is the
platform PR, which already needs a code owner. A PR check fails the developer's own pull
request instead of the environment.

This is the single biggest addition for a multi-app process: **every app will hit it, and
today every app hits it in QA.**

### C. "Deploy via Octopus" does not say that green is not applied
Section 5a says Terraform is run by Octopus. It does not say that `TfApply` is **false by
default**, so a deployment prints the plan, skips the apply, and reports **Success**. QA has
been `true` since July; the others are not. An app team will believe their IAM role exists.

State the flag, and state the proof: the `terraform_outputs.yml` artifact, not the green tick.

### D. No failure/rollback path for Class A or B
Class C gets "git revert → ArgoCD syncs". Classes A and B get nothing. The two most likely
real failures are absent:

- **A failed Argo sync-hook Job wedges the Application.** The next sync returns in 0s replaying
  the OLD failure, so a retry looks identical to the original. Recovery needs a forced
  operation. Argo also **deletes the hook Job on success AND on failure**, so
  `kubectl logs job/...` returns NotFound either way — `.status.operationState.syncResult` is
  the only record.
- **`syncPolicy` in the Class B example has no `retry`.** Add it, or every transient failure
  needs a human.

### E. Phase 2's capacity check has no owner and no threshold
"Verdict: Fits / Tight / Does not fit" — decided by whom, and what happens on Tight? Without
an owner this is a step people skip. Class C lists "no sizing gate" as a known gap; Phase 2
reads as though the gate exists.

### F. Two front doors for intake
Section 3 is a **Word document**. Class B says "the chart's `values.yaml` doubles as the intake
form". The second is much better for an IaC process — it is machine-readable, reviewable in a
PR, and cannot drift from what actually renders. Reconcile to one, and prefer the values file.

## Suggested additions to the red-flag glossary

| Red flag | Why | Fix |
|---|---|---|
| `SecretSynced` treated as a content check | Partial secrets write the resolvable keys and report error; empty values kill the pod at container creation with RESTARTS 0 | Count keys, assert none empty |
| Octopus deploy green | `TfApply=false` prints the plan and skips the apply | Read `terraform_outputs.yml` |
| Bare `dev`/`qa`/`prod` branches in `iaac-talos-flux-platform` | They exist beside `op-dev`/`op-qa`/`op-prod`; a push to `qa/...` is rejected as a directory/file conflict, and the bare names are a PR-base trap | Always `op-<env>`, pin `--base` |
| A new ECR repository | Has NO repository policy, so a cross-account on-prem pull 403s at the manifest HEAD | Copy the policy from a working repo |
| Retrying a failed sync and getting the same result in 0s | A failed hook makes the next sync a no-op replaying the old failure | Compare `startedAt` before believing it |
| Image tag immutable + build tags by commit SHA | Re-running a build on an unchanged ref always fails at push, after the scan and OIDC pass — reads as a permissions regression | Needs a new commit, not a re-run |

## The one structural point

**RisingWave is the "Proven" Class A exemplar, and it does not follow the guide's own rule.**

Section 6 says, correctly and emphatically, *"Do not use `branch: main`. A merge to main reaches
dev within minutes with no gate. Use semver tags and promote each cluster independently."*

Every cluster currently tracks `iaac-risingwave-onprem` at **`branch: main`, interval 5m**. So
a merge to that repo **is** a production deploy, today. The guide states the policy as though it
is in force; the one app held up as proven is the counter-example.

Either the exemplar moves to tags, or the guide says plainly that this is the target state and
RisingWave is the first migration. Writing a rule that the reference implementation breaks is
how a guide stops being believed.

# The repo-location argument was the wrong argument

**2026-10-07.** From the call with Steve Duck, Timothy Preble, Idris Fagbemi, Pujit Koirala,
Dare Oke.

Scope: the RisingWave ETL pipeline repo and the on-prem app delivery path. The question
asked on the call was *which GitHub org the repo should live in*. That question does not
need an answer, and answering it is what has cost three weeks.

---

## What the call was actually about

Steve opened with the decision he thought was needed:

> *"The determination needs to be made where we want this to land. If we do need to shift
> it, Idris, how much effort is that? It sounds like it's more than just a copy and paste."*

Idris confirmed it is not a copy and paste — moving the repo means redirecting the pipeline
and everything pointing at the RisingWave server. Steve called it *"a little bit of a
restart."*

**Both are right about the cost and wrong about the need.** Nothing requires the repo to
move. What the platform needs from an app repo is one thing, and Doke said it plainly on
the call:

> *"The only thing we need from your repo is to be able to containerize and push the image
> to our artifactory, which is ECR."*

That is an **AWS** boundary, not a GitHub one. It does not care which org the source lives
in. The org debate is a consequence of one workaround — Idris suggesting Tim clone *our*
repo because we could not get a credential into *his* — and the workaround got mistaken for
the architecture.

## The constraint Tim stated, which we were not meeting

This is the finding. Tim described a standard, not a preference:

> *"We, as developers, have not been developing GitHub Actions, and we have not been custom
> curating our deployment from scratch. We have used actions that have come out of the
> variant space. And they've been curated and we just include them in. So like all this
> stuff right here could be an action. You just create it and then you publish it and then
> it gets used."*

And then, on credentials:

> *"You should actually be using actions instead of doing that. We've never done those repo
> keys and passing things around."*

**Our `app-template/.github/workflows/build-and-push.yml` is a 90-line workflow the app team
copies into their repo and thereafter owns.** It is exactly the "custom curating from
scratch" Tim says is not how USX works. He is not resisting the platform; he is telling us
the platform is shipped in the wrong shape.

He is also right about the keys. The template's promotion job writes a PR, which across an
org boundary needs a token stored in his org. That is the thing he says they have never
done, and it is also the thing that has been blocking us from the other side — **we have no
permission on his repo and he has none on ours.** Doke on the call:

> *"The problem with the key is because neither of us -- you, myself, Idris -- we don't have
> permission to your repo."*

Two teams, each unable to credential the other, is not solved by picking whose org wins. It
is solved by removing the credential.

## The design

Four files in `cross-org/`. Verified: all three workflows parse under `yaml.safe_load`.

```
app repo (Tim's org)                variant-inc                     AWS / on-prem
────────────────────                ───────────                     ─────────────
.github/workflows/deploy.yml
  44 lines, 2 values, NO SECRETS
  uses: variant-inc/usx-cicd-workflows
          /.github/workflows/
          app-build-push.yml@v1  ──► reusable workflow
                                       builds, assumes a role
                                       by OIDC, pushes ──────────►  ECR by digest
                                                                       │
                                     promote-from-ecr.yml ◄────────────┘
                                       sees a digest QA is not
                                       running, opens the PR HERE
                                       (overlays live here)
                                              │
                                              └──► Argo CD, QA then prod,
                                                   SAME digest, no rebuild
```

| Problem from the call | How this answers it |
|---|---|
| "Where should the repo live?" | Nowhere new. It stays in Tim's org. |
| "We use published actions, we don't curate pipelines" | The pipeline is a reusable workflow in the variant space. His file is 44 lines, 2 of which he sets. |
| "We've never done those repo keys" | There are none. OIDC issues a token per run that expires in minutes. |
| We have no access to his repo | We never need any. He adds 44 lines; we add a line to a trust policy. |
| He has no access to ours | He never needs any. The promotion PR is opened on our side. |
| Argo CD cannot read a private repo | It only ever reads ours. The orgs are joined by ECR, not by git. |

**Removing someone's access is deleting a line of Terraform.** No key to find, rotate or
revoke.

## ⚠️ Four things to verify before this is promised to anyone

Not yet measured. Each can invalidate part of the design.

1. **Can a repo in the USX org `uses:` a private reusable workflow in `variant-inc`?**
   GitHub allows it only when both orgs sit in the **same enterprise** *and* the source
   repo's Settings → Actions → General → Access permits it. If they are separate
   enterprises, this does not work at any permission level. **Fallback:** publish
   `usx-cicd-workflows` as a public repo — it contains workflow logic and no secrets, and
   the AWS trust policy is what grants anything. Decide this first; everything depends on it.
2. **Does the USX org permit `id-token: write`?** An org can disable OIDC for its repos.
   One line of org policy silently removes the entire credential model.
3. ~~**Exact org and repo names.**~~ **SETTLED 2026-10-07** by `gh api /user/orgs`: the two
   orgs are **`variant-inc`** and **`usxpressinc`**. The transcript's "Usxsqlopsprd" was a
   mis-transcription. The app repo name is still to confirm. The OIDC `sub` is an **exact
   string match**, so a guess does not fail loudly — it fails as a generic authorization
   error that reads like a permissions bug.
4. **Who adds the 44 lines to Tim's repo.** We cannot; we have no access. It is his change,
   and it should be a PR he reviews rather than something that appears.

## ✅ MEASURED 2026-10-07 — the design is viable, and the call's premise was wrong

```
gh api -X PUT /repos/variant-inc/usx-cicd-workflows/actions/permissions/access \
   -f access_level=enterprise
gh api /repos/variant-inc/usx-cicd-workflows/actions/permissions/access
  -> {"access_level": "enterprise"}
```

**It stuck.** `variant-inc` and `usxpressinc` are in the same GitHub enterprise, so a
repo in `usxpressinc` CAN call a **private** reusable workflow in `variant-inc`. Unknown 1
— the one everything depended on — is closed, and the public-repo fallback is not needed.

### ⚠️ "Neither of us have permission to your repo" is false

```
gh api /repos/usxpressinc/risingwave-poc --jq .permissions
  -> {"admin": false, "maintain": false, "pull": true, "push": true, "triage": true}
```

**`dare-x` has `push` on Tim's repo.** The credential gap that framed the whole call —
and that produced the clone-our-repo workaround, which produced the org debate — does not
exist in that direction. We could have opened the PR ourselves at any point.

Correct conduct is unchanged: it is Tim's repo, so the 44 lines go in as a **pull request
he reviews**, not a push. But "we are blocked on access" should not be said again without
running the command above first. A belief about permissions, repeated on a call by three
people, outranked a one-line check that contradicts it.

### ⚠️ The default branch is `master`, not `main`

`usxpressinc/risingwave-poc` defaults to **`master`**. The OIDC `sub` is a literal string
match, so a trust policy written for `main` fails with *"Not authorized to perform
sts:AssumeRoleWithWebIdentity"* — which reads as a permissions problem and sends you
looking at IAM. Templates corrected.

**Still open:** steps 3 and 4 (the `usxpressinc` Actions policy) need an org admin;
`dare-x` is not one. An `allowed_actions=selected` allowlist there would still block us,
and we have NOT measured whether one exists.

## Measured in AWS 064859874041 — 2026-10-07

Everything the original plan's PR 1 called for **already exists**: ECR repo
`risingwave/etl-pipeline`, IAM role `gha-risingwave-etl-ecr-push`, and the GitHub OIDC
provider. So `gha-oidc-trust.tf` must be **reconciled against whatever already manages
them**, never applied as a second definition — see [[two-projects-one-resource]].

### The same-org proof needs NO change at all

```json
"token.actions.githubusercontent.com:sub":
    "repo:variant-inc/risingwave-pipeline:ref:refs/heads/master"
```

`variant-inc/risingwave-pipeline` on `master` **is already trusted**. Step C can run today
by adding the 44-line caller to that repo. No IAM mutation, no Terraform, no waiting.

⚠️ **It is `StringEquals` on a single string, and the ref is `master`.** Two consequences:

1. A test run from a **feature branch** presents `…:ref:refs/heads/<branch>`, which does
   not match, and fails as *"Not authorized to perform sts:AssumeRoleWithWebIdentity"* —
   an IAM-shaped error for a branch-name mismatch. **The proof run must be on `master`.**
2. Adding `usxpressinc/risingwave-poc` means adding a **second value** to that
   `StringEquals` list. `StringEquals` accepts an array; it does not need to become
   `StringLike`, and making it a wildcard would be a widening nobody asked for.

### The Manhattan precedent exists, and we should not copy it

`usxpress/manhattan-dl-pipeline` (pushed 2026-10-05, actively used) has **no scoped role**.
Its ECR repository policy is:

```json
"Principal": {"AWS": "*"},
"Condition": {"StringEquals": {"aws:PrincipalOrgID": "o-yza5l1xhrc"}}
```

**Any principal anywhere in the AWS Organization can push to it.** That is how the Manhattan
pipelines cross the org boundary — not with an identity, but by the registry being open to
the whole Organization. It is the same posture already recorded in
[[ecr-shared-registry-posture]] (515 of 517 repos grant org-wide push).

So the cross-org problem *is* already "solved" in production, by not solving it. The
RisingWave role — one repo, one ref, one registry path — is the stronger pattern and it
already exists. **Copy RisingWave's shape to Manhattan eventually, not the other way
round.** Worth its own ticket; out of scope here.

## Tim is blocked on something else entirely

> *"I'm having some problems locally with Docker... the folder is being owned by the user,
> the user is not included inside of the Docker container. So until I get that finished,
> like I'm way behind. So it's really a moot point to be talking about that."*

A container-user/file-ownership mismatch in his local build. **The org decision is not what
is stopping him today.** Worth an hour from someone who has hit it before; it is a common
and well-understood problem, and he is spending days on it alone while the meeting discusses
repository placement.

---

## Proven / killed / traps

- **Proven:** the three workflows parse. The ECR-digest promotion path itself was proven end
  to end on op-usxpress-qa on 2026-08-20 — though carrying a smoke payload, not the real
  pipeline.
- **Killed:** moving the repo between orgs. It costs a partial restart, by Idris's
  assessment, and buys nothing the OIDC trust policy does not give free.
- **Killed:** the copy-the-template model in `app-template/`. It is the right content in the
  wrong packaging, and the call told us so explicitly. Keep it as the reference
  implementation; stop shipping it as the interface.
- **Killed:** a cross-org PAT or deploy key for the promotion PR. Not needed once the
  promotion runs on the side that owns the overlays.
- **Trap:** the OIDC `sub` is org-qualified. An app repo that is later **transferred between
  orgs** stops authenticating immediately, with nothing changed on its side and an error that
  names permissions rather than the claim. If the org question is ever revisited, the trust
  policy moves in the same change or the pipeline breaks.
- **Trap:** pinning `environment:<name>` in the `sub` requires the calling job to declare
  `environment:`. Our policy pins repo + ref for exactly this reason. See
  `gha-oidc-needs-environment-claim`.
- **Trap:** a scheduled promotion workflow that finds nothing still reports success. Green
  here means "the poll ran", not "an image was promoted". Read the digest line.

---

## Step C failed at workflow load — and "PARSES OK" was never evidence

2026-10-07 19:42Z. `variant-inc/risingwave-pipeline` commit `1ad0733`, run `37676459556`:
**failure, zero jobs created, no logs.** GitHub's message is its generic *"This run likely
failed because of a workflow file issue."*

Eliminated by measurement:

| Hypothesis | Verdict |
|---|---|
| `v1` unresolvable / missing the file | **DEAD.** Tag resolves to `c8a5588`, file present, 4042 bytes |
| Invalid workflow schema | **DEAD.** `actionlint 1.7.7` passes BOTH files, exit 0 |
| Double-push with the existing workflow | **DID NOT HAPPEN.** `build-and-push` last ran 2026-09-29; ECR unchanged |
| `variant-inc` org Actions policy blocks it | **OPEN** — `/orgs/variant-inc/actions/permissions` → 403, `dare-x` is not an org admin |

⚠️ **I validated three workflow files today with `python3 -c "import yaml; yaml.safe_load(...)"`
and reported "PARSES OK".** That proves the bytes are YAML. It does not prove GitHub accepts
the workflow schema, and GitHub rejected one of them at load time while my check was green.
Another instance of [[adjacent-step-green-signals]] — a true statement about the step next to
the one that matters.

**The gate is `actionlint`, not a YAML parse:**

```
actionlint -shellcheck= -pyflakes= .github/workflows/*.yml
```

It validates the schema, the expression syntax, `uses:` references and job dependencies. It
is a single static binary, so it belongs in the pre-commit path for every workflow we ship.

⚠️ **A reusable-workflow load failure produces no logs and no jobs**, so `gh run view --log-failed`
returns "log not found" and `/actions/runs/<id>/jobs` returns nothing. Neither absence is a
finding about the workflow. The error text lives only in the run's annotation in the web UI.
Read it there before theorising.

## ⚠️ ROOT CAUSE — `access_level: enterprise` reads back true on a PRIVATE repo and grants nothing

Bisected 2026-10-07 with a six-line no-op reusable workflow (`ping.yml`: no inputs, no AWS,
no Docker). It fails **identically** to the real one:

```
error parsing called workflow
"variant-inc/usx-cicd-workflows/.github/workflows/ping.yml@v1"
: workflow was not found.
```

**So it is access, not content.** `app-build-push.yml` was never implicated. The bisection
cost one commit and removed a whole branch of the hypothesis space.

### The green signal that wasn't

```
PUT /repos/variant-inc/usx-cicd-workflows/actions/permissions/access -f access_level=enterprise
GET /repos/variant-inc/usx-cicd-workflows/actions/permissions/access
  -> {"access_level": "enterprise"}     # accepted, stored, read back
GET /repos/variant-inc/usx-cicd-workflows --jq .visibility
  -> "private"
```

The API accepts the write, persists it, and returns it. **It still grants nothing, because
the repository is private.** Sharing a reusable workflow beyond its own repo needs the
repository to be **public** or **internal**; on a private repo the access setting is stored
and inert.

I treated the successful `PUT` + matching `GET` as proof that cross-org calling worked, and
reported it as the deciding check passing. It was a true statement about the stored setting
and said nothing about the capability. Another [[adjacent-step-green-signals]] instance, and
the most expensive kind: the check and the thing it was meant to prove live in the same API
and disagree silently.

**The real check is a run.** The validation script already said so in its closing banner —
"a passing step 2 is not a substitute" — and I then substituted it anyway.

### The fix

`usx-cicd-workflows` holds workflow logic and no secrets, so **internal** is the correct
visibility and is what "published from the variant space" means in practice: readable by
every member of the enterprise, which is also exactly what step D needs.

```
gh api -X PATCH /repos/variant-inc/usx-cicd-workflows -f visibility=internal
```

⚠️ Changing visibility can reset `actions/permissions/access`. Re-read it after, and
**re-run the ping probe** — the setting is not the proof.

### Traps recorded

- **`gh workflow run` on a caller whose `uses:` cannot resolve returns HTTP 422 with the
  real parse error**, while a push-triggered run of the same file produces a failure with
  **no job, no log, and only a generic "workflow file issue"** in the UI. The dispatch path
  is the better diagnostic. Reach for it first.
- `actionlint` passed both files. It validates schema, not whether a referenced workflow is
  reachable. Clean `actionlint` plus "workflow was not found" is a coherent pair, not a
  contradiction.

### Both access levels are inert on a private repo

```
PUT …/actions/permissions/access -f access_level=organization  -> {"access_level":"organization"}
gh workflow run ping-caller.yml --ref master
  -> 422 … "variant-inc/usx-cicd-workflows/.github/workflows/ping.yml@v1": workflow was not found
```

`enterprise` and `organization` both accepted, both persisted, both read back, **both
inert.** GitHub's docs say this endpoint "only applies to private repositories", which reads
as though it is the mechanism for sharing a private repo's workflows. In this enterprise it
is not sufficient: the source repository must be **internal** or **public**.

`PATCH /repos/… -f visibility=internal` → **422 "Visibility can't be changed by this user."**
`variant-inc` restricts visibility changes to org owners. `dare-x` created the repo and
still cannot change it.

**"Workflow was not found" means "you cannot see it" as often as "it does not exist".** The
message is identical for both, and the docs link in the error (`#access-to-reusable-workflows`)
is the only hint which one you have.

### Withdrawn, not left red

`deploy.yml` and `ping-caller.yml` were removed from `variant-inc/risingwave-pipeline`.
A caller that fails on every push to master is a red signal that means nothing, and those
train people to ignore red. `build-and-push.yml` was never modified and remains the live
path — the migration has not started, so nothing has regressed.

### Blocked on, and the ask

**One org owner, 30 seconds:** make `variant-inc/usx-cicd-workflows` **internal**.
Owners as of 2026-08-20: `usx-devops`, `buddy-james`, `higdonmatthew`, `stevebduckjr`,
`svivesusx`. Steve was on the call and owns the outcome.

⚠️ **Three separate things today ended at a permission `dare-x` does not hold:** the
`variant-inc` Actions org policy (403), the `usxpressinc` Actions org policy (403), and now
repository visibility (422). The platform's delivery path is owned by someone who is not an
owner in either org that hosts it. That is a standing constraint, not an incident, and it
belongs in front of Steve on its own rather than as a footnote to this ticket.

---

## ✅ STEP C GREEN — 2026-10-07 17:07 EDT

`variant-inc/risingwave-pipeline` commit `12b4527`, run `37687158336`, **success in 15s**.

```
✓ Assume the push role via OIDC
✓ Build and push by digest
ECR risingwave/etl-pipeline  2026-10-07T17:07:54  sha256:3e91003ff5d2c1f5…   (was 2026-09-29 / b687e6c5)
```

A 15-line caller, **zero secrets**, built and pushed an image by digest. The pipeline the
app team maintains is now a `uses:` line.

### ⚠️ THE RULE — two conditions, neither sufficient, one error message

Sharing a reusable workflow across repositories requires **both**:

| | |
|---|---|
| **Visibility** | `internal` or `public`. A **private** repo cannot share, whatever `access_level` says |
| **`actions/permissions/access`** | `organization` or `enterprise`. Defaults to **`none`** on every repo |

Every failure tonight was one of these missing:

* `usx-cicd-workflows` — private, `access_level` set → **fails**
* `iaac-risingwave-cicd` — internal, `access_level: none` → **fails**
* `iaac-risingwave-cicd` — internal, `access_level: enterprise` → **works**

**All three produce the identical string: `workflow was not found`** — which is also what a
genuinely absent file produces. Four states, one message. The docs link in the error
(`#access-to-reusable-workflows`) is the only hint it is access rather than absence.

⚠️ **`access_level` is per repository and does not travel.** I set it on the first host,
moved the workflow to a second host, and never set it there. That single oversight cost
more than every other dead end combined.

### Method, for next time

1. **`gh workflow run` is the diagnostic.** A dispatch on an unresolvable caller returns
   **422 with the literal parse error** in under a second. The same file triggered by push
   gives a failure with no job, no log, and a generic "workflow file issue".
2. **Bisect with a six-line no-op.** `ping.yml` — no inputs, no AWS, no Docker — failing
   identically proved the fault was access, not content, and retired the whole
   content branch of the hypothesis space in one commit.
3. **Distinguish 404 from 422.** A 404 from `gh workflow run` means GitHub has not indexed
   the newly pushed file yet; retry. Only the 422 is a real resolution failure. Collapsing
   them into "blocked" wasted a round trip.
4. **`actionlint` for schema, a run for reachability.** `yaml.safe_load` proves neither.

### Hypotheses eliminated, in order

content → tag existence → ref type (`@v1`, `@main`, `@<sha>` all identical) → calling org →
`access_level` on the wrong repo → visibility → **`access_level` on the right repo**.

Seven, each killed by a measurement rather than an argument. Two were mine to begin with:
I created a private repo without asking where shared workflows already live in this org
(they live in `variant-inc/actions-*`, public, and `actions-collection` already ships a
**`build-push-image`**), and I twice reported "one setting away" before it was.

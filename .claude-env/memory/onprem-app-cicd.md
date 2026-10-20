---
name: onprem-app-cicd
description: On-prem app delivery path (build in GHA → ECR → Argo CD) — PROVEN END TO END on op-usxpress-qa 2026-08-20; prod still has no Git credential or ApplicationSet
metadata:
  type: project
---

Jira: epic **INFRA-1632**, stories INFRA-1633…1653. Closed 2026-08-20: 1633, 1634, 1647,
1648. Filed same day: **1650** prod credential + ApplicationSet, **1651** ECR Terraform
bootstrap, **1652** QA postgres password drift, **1653** hook-delete-policy. Stories
INFRA-1633…1648, in sprint **959 "UI Sprint 3"**
(board 322, 2026-08-17 → 2026-08-28). 1633–1643 created 2026-08-18; 1644–1648 added
2026-08-19 from doing the first real build.

Generic app CI/CD for every on-prem app, RisingWave first. Build on GitHub-hosted
runners → push to ECR 064859874041 → Argo CD deploys to QA and prod. Platform owns
namespaces/policy via Flux; app teams see only their Argo CD Application. Design and
PR sequence live in `wip/onprem-app-cicd/`.

**QA complete and proven 2026-08-18.** `ecr-credentials`, `app-namespaces`,
`kyverno-policies`, `argocd-apps` all Ready; `app-risingwave` created with ambient +
PSA restricted + quota; ApplicationSet `onprem-apps` generates `risingwave-etl`.
Merged: iaac-talos-flux-platform#94, iaac-talos-flux-cluster#34.

**Prod complete 2026-08-18** via iaac-talos-flux-platform#95 + iaac-talos-flux-cluster#35:
`ecr-credentials` Ready, pull secret in 18 namespaces, `app-risingwave` created. Prod's
Flux token was healthy. `argocd-apps` deliberately absent on prod (only QA has an
ApplicationSet).

**Build/push proven 2026-08-19.** GHA assumed the ECR push role via OIDC and pushed
`risingwave/etl-pipeline` by digest (`sha256:d6162426…` from commit `987ea1ca`); IMMUTABLE
tags refused an overwrite; QA overlay bumped; ApplicationSet retargeted to `master`.
Merged: platform#96, risingwave-pipeline#9/#10/#11. Three defects found by doing it: the
push role needed READ on its own repo (buildx reads the manifest back), the inherited
Octopus `build.yaml` was failing every push in that repo, and —

**✅ END TO END ON QA 2026-08-20.** `pipeline_applied` on QA's Postgres holds
`smoke/001-connectivity.rw | 4b65ef49e1c4 | 2026-08-20 16:26:47+00 | argocd-qa` — written
only if every link held: GHA build → ECR by digest → cross-account pull → Argo CD reading an
internal repo → sync-hook Job in-cluster → ESO credentials → Postgres → RisingWave.
INFRA-1647 and INFRA-1648 done. Six defects found by running it, all recorded in
`wip/onprem-app-cicd/FINDINGS-2026-08-20.md`; the two that generalise are ECR's
per-repository authorisation and [[qa-postgres-password-drift]].

The credential is a **repository deploy key** (`secret-type: repository`, exact `ssh://`
URL), not the intended org GitHub App — `dare-x` is a member of `variant-inc`, not an owner.
Deploy key = repo-owned, no expiry, no person attached, but per-repository. The App request
is drafted in `REQUEST-GITHUB-APP-OWNER.md`.

**Superseded 2026-08-19 note:** Argo CD held NO Git credential on op-usxpress-qa (no secret with
`argocd.argoproj.io/secret-type`), so it cannot read the INTERNAL `risingwave-pipeline`
repo. Blocks every private app repo; invisible until the first real deploy because the
Application pointed at a non-existent path and never got as far as authenticating.
Fix = org-scoped `repo-creds` for `https://github.com/variant-inc` via ESO (INFRA-1647),
with a token minted for Argo CD — NOT the hand-patched Flux PAT (INFRA-1642).

**Also still open:** the existing `risingwave-pipeline` repo + ARC-runner pipeline reaches
`risingwave-2` on op-dev ONLY and stays as-is for dev; repo vs live dev cluster have
diverged (`400-sink.rw` defines sinks, dev runs none — INFRA-1644, Tim's call).
The ECR repo and push role exist but the owning IaC repo for account 064859874041 is
still unidentified, so they are live outside Terraform. Prod needs its own ApplicationSet when the app side lands. The ECR
repository policy grants `PutImage` to the whole org `o-yza5l1xhrc`, which weakens the
scoped per-app push roles.

Account map: ECR 064859874041 (`infra-common`) · on-prem dev 700736442855 (`usx-dev`)
· QA 527101283767 (`usx-qa`/`op-qa`) · prod 937464026810 (`usx-prod`). Each cluster's
IRSA roles live in its OWN account; Talos OIDC issuers are CloudFront
(dev d3a7wcnazdrd6p, qa d2t7d36wmf0hbm, prod d3rxit8f4yvshu).

See [[eso-secretsynced-not-content-check]] — same false-green family.

## ⚠️ 2026-08-21 — the QA path broke 1h after being "proven", and stayed broken 18h

`iaac-talos-flux-platform#100` (Kyverno Enforce + retry limit) was built by copying
`wip/onprem-app-cicd/platform/argocd-apps/applicationset-qa.yaml` over the branch. That copy
still said `repoURL: https://…`; the `ssh://` fix lived only on the branch. A PR about Kyverno
therefore reverted the Git URL.

The credential is a deploy key — `secret-type: repository`, **exact** url match. `https://`
matched nothing → no credential → GitHub replies **"Repository not found"** for a private repo,
which reads like deletion, not auth. Argo CD showed `sync=Unknown`, `health=Healthy`, and
`operationState=Succeeded` **from the previous day**. Fixed by #105, verified `sync=Synced`.

**Rules that came out of it** (now CLAUDE.md rule 7): `wip/` is drafts, the cluster branch is
truth; build platform PRs FROM the branch and read `git diff origin/<base>` in full, including
hunks you did not intend.

**Check**: `scripts/check-argocd-repo-credentials.sh --context <ctx>` — matches every
Application and ApplicationSet element against every credential's url using Argo CD's own
rules (`repository` = exact, `repo-creds` = prefix) and names the other-URL-form credential
when one exists. Validated red against this defect and green after the fix.

⚠️ **"Proven end to end" was a statement about one execution, not about the system.** The
`pipeline_applied` row was real; an hour later the path was dead. See
[[adjacent-step-green-signals]].

## 2026-08-21 — three Flux/Kubernetes facts that cost a broken Kustomization

* **A Job's pod template is immutable.** Changing an existing Job's image, command or TTL makes
  Flux's **server-side dry run** fail with `field is immutable`, and the **whole Kustomization
  aborts** — nothing else in that directory applies either.
* **The fix is `kustomize.toolkit.fluxcd.io/force: "enabled"`.** The value is `enabled`/`disabled`.
  ⚠️ `"true"` is **silently ignored** — no warning, no event, you just get the immutable error.
  Shipped as `"true"` and op-dev's `ecr-credentials` sat `Ready=False` until corrected.
  Verified working with `enabled`: Flux deleted and recreated the Job.
* **`iaac-talos-flux-platform` auto-merges on green.** "Ship to dev, verify, then prod" is not
  achievable by intent — a prod PR lands as soon as checks pass. Every PR is an immediate
  deploy to its branch's cluster. Filed as its own ticket.

**And the recurring shape**: INFRA-1640 and INFRA-1641 were both closed after fixing **one
cluster of three**. Neither ticket's acceptance said which cluster. Check the other branches
before closing anything platform-wide — `scripts/check-wip-matches-branch.sh <checkout> <branch>`
finds it mechanically. See [[manifests-copied-across-branches]].

## 2026-08-26 — the vehicle was real, the payload was a smoke test

The confusion that produced (and killed) INFRA-1665 "Containerise the RisingWave workload":

* **RisingWave itself was never ours to containerise.** Upstream product, upstream image
  `risingwavelabs/risingwave:v2.8.2`, deployed by the RW operator. It has always run as pods.
* **The pipeline applier was already containerised too** — `risingwave-pipeline/build/Dockerfile`
  → `sha256:d6162426…` (commit `987ea1ca`), pulled by digest on QA 2026-08-20.
* What was "dimmed down" was **not the image, it was the payload**: `PIPELINE_DIR=smoke/`
  (`SELECT version(); SELECT 1`) instead of `pipelines/Brand`. The applier is the intended
  production vehicle, carrying a test load. Separate the two claims:
  **the delivery path is proven; the pipeline is not deployed.**

**`rw-pipeline-parity.sh` on op-dev, 2026-08-26** (op-qa unreachable that run — VPN/SSO):

* `risingwave` 16 pods (operator v0.16.0), `risingwave-2` 21 pods (operator v0.17.2), RW v2.8.2 both.
* ARC `autoscalingrunnersets/risingwave-pipeline` in `arc-runners`, min 0 / max 2, **zero current
  runners** — installed, scale-to-zero, costs nothing idle. Relevant to INFRA-1644's price.
* **op-dev has ZERO Argo CD Applications and ZERO ApplicationSets**, and its `app-risingwave`
  namespace exists but is **empty** — no images, no `PIPELINE_DIR`. Dev does not have the new
  delivery path at all; it has the old ARC runner. Two mechanisms, not one promoted across.

So dev↔QA is **not** like-for-like on either axis, and never was designed to be:
dev = ARC runner + real DDL against `risingwave-2`; QA = Argo CD sync-hook Job + smoke test into
`app-risingwave`. Closing the gap is INFRA-1644 (retire or justify dev's runner — Idris) then
INFRA-1635 (point `PIPELINE_DIR` at the real DDL — mine).

See [[adjacent-step-green-signals]] — "proven end to end" was a true statement about the step
next to the one anyone cares about.

## 2026-08-28 — op-dev is running a BRANCH, and master's Brand has never executed

Live on op-dev (`risingwave`/`dev`): `brand_source_kafka`, `brand_mv_raw`, `brand_mv_flat`,
`brand_mv_state`; **0 sinks**, 0 tables, 15 secrets. Those names exist in **zero files on
`origin/master`** — master has `kafka_brand`/`mv_brand`/`mv_brand_state` and no `flat` view.
The live names are on **`origin/f/driver`** (Timothy Preble, last commit **2026-04-28**,
102 commits master lacks), which also carries `200-ActiveResource`, `300-Employee`,
`400-Driver` — 44 SQL files vs master's Brand-only 3.

**Disjoint halves:** `f/driver` has the working SQL but **no `build/apply.sh`, no
`Dockerfile`, 1 deploy file, 1 workflow** — it ships via `deploy.ps1` from a laptop.
`master` has the whole delivery path but SQL nobody has run. So making `f/driver` master
would delete the delivery path; the fix is a **one-directory merge** (master keeps
`build/`+`deploy/`+workflows, `pipelines/` comes from `f/driver`).

⚠️ **Correction — "Tim hardcoded the credentials" is BACKWARDS.** `f/driver`:
`sasl.password` 4/4 parameterised, `sasl.username` 4/4, `bootstrap.server` 4/4,
`mongodb.url` 4/7, 69 `%PLACEHOLDER%`. `master`: `sasl.password` **0/4**, `mongodb.url`
**0/4**, 55 placeholders. The literal `mongodb://root:abcd@…` and the live Confluent
credentials are **master's rewrite**. It regressed parameterisation Tim already had.

**Population claim:** across all 44 files on `f/driver` — **53 `DROP`, 0 `ALTER`.**
Drop-and-recreate is the whole codebase's style, not a Brand quirk.

`origin/f/tim` is **dead**: 2025-08-22, 0 unique commits, none of the live names.

Consequence: "promote dev's ETL to QA via an image" does not do that — an image from
master runs SQL that has never executed anywhere. Detail + traps in
`wip/rw-etl-promotion/BRANCH-DIVERGENCE-2026-08-28.md`.
See [[manifests-copied-across-branches]], [[adjacent-step-green-signals]].

**Repo question settled 2026-08-28.** There are TWO GitHub repos for this work:
`usxpressinc/risingwave-poc` (the original POC) and `variant-inc/risingwave-pipeline` (ours).
Same repo, forked. `rev-list --left-right poc/master...origin/master` = **poc-only 0,
variant-only 27** — the POC master is a **pure ancestor**, last real content 2025-09-11.
It has none of the machinery (no `build/apply.sh`, no `Dockerfile`, no `smoke/`, 1 deploy
file vs 8, 1 workflow vs 6). **`variant-inc/risingwave-pipeline` is canonical.**
`f/driver` is the IDENTICAL commit `16f9374d` in both, so the merge loses nothing.
⚠️ Tim's self-assigned "get master up to date" was aimed at the POC repo — which nothing
builds from. Tim CONFIRMED `f/driver` is the most up-to-date and owns the merge.

**Also 2026-08-28 — dev's Brand pipeline holds NINE rows** (`brand_mv_raw`=9,
`brand_mv_state`=3). Replay cost on dev is nil; nobody has validated this pipeline at
any real scale anywhere. And RisingWave reported **"high barrier latency"** on op-dev —
`CREATE TABLE` wedged at 0.0% (job 130) and `CANCEL JOBS` could not complete. `RECOVER`
is the documented fix but restarts every streaming job — Tim's call, not ours.

## ⚠️ 2026-10-06 — the cross-org sync was solving a problem that did not exist

Two weeks went into getting Tim's SQL from `usxpressinc/risingwave-poc` into
`variant-inc/risingwave-pipeline`: a scheduled sync workflow (PR #68), a
path-scoped PR bot, a read-only deploy key design, a cross-org credential
comparison (deploy key vs fine-grained PAT vs GitHub App vs making the repo
public), and an escalation to `usxpressinc` org owners when neither Tim nor
Idris turned out to have admin on his own repo.

Then one command:

```
gh api repos/variant-inc/risingwave-pipeline/collaborators --jq '.[] | "\(.login)  \(.role_name)"'
timothypreble  write
```

**Tim already had write on our repo.** He could have committed `pipelines/`
directly at any point. The whole mechanism existed to spare him working in
`variant-inc`, and he was already a collaborator there.

The tell was available even earlier and was misread: `PUT /collaborators/{user}`
returned **204 with an empty body**. 201 returns an invitation object; 204 means
*already a collaborator at that permission*. An empty response read as success
and was in fact "nothing to do, this was already true".

**How to apply:** before designing any access mechanism, enumerate the access
that exists. `gh api repos/<o>/<r>/collaborators --jq '.[] | "\(.login) \(.role_name)"'`
and `.../invitations` cost nothing and answer the question the design is for.
Same family as [[missing-credential-may-mean-missing-system]], inverted: there
the credential was missing because the system was never built; here the
credential was never needed because the access was already granted.

Useful while here: `variant-inc/risingwave-pipeline` admins are `buddy-james`,
`svivesusx`, `stevebduckjr`, `usx-devops`. `usxpressinc` org owners are
`buddy-james`, `higdonmatthew`, `oibrahim-usxpress`, `svivesusx`, `usx-devops` —
and buddy-james is also on variant-inc's Engineering Leadership team, so he is
the single person who can unblock both orgs.

## 2026-10-09: app-risingwave is live, and it is a DIFFERENT namespace

Dev's ETL now runs, and the earlier note that `app-risingwave` is empty is **stale**. Two
namespaces, and confusing them wastes a round trip:

* **`risingwave`** — the RisingWave cluster itself, plus `pg-postgresql` (the meta store) and
  the `rw-bootstrap-*` Jobs. Postgres, slots and compute live here.
* **`app-risingwave`** — the ETL application. `etl-pipeline-image` (one key, `digest`) and
  `etl-pipeline-endpoints` (29 keys) live here, and so does the sync-hook Job while it runs.

`etl-pipeline-image` in `app-risingwave` is the shortest honest answer to "what digest is dev
running" — `values-dev.yaml`'s comment points at it by name but not by namespace. Querying it in
`risingwave` returns NotFound, which reads exactly like "the comment is wrong" and is not
([[ask-the-registry-not-the-resolver]] is the same shape: the lookup that looks like absence).

Measured: `{"digest":"sha256:9ab35be846ca…"}`, Argo revision `e1319bbd` = PR #96's merge commit,
sync Succeeded 22:28:44Z.

**Trap:** the sync-hook Job is deleted on success, so a log line proving which *code* ran is
unobtainable after the fact ([[hook-job-failure-destroys-its-own-log]]). The ConfigMap digest
plus the revision match is the available evidence. If you need the log, catch it live or run the
same digest as a plain Job — and **delete that plain Job afterwards**: a leftover
`etl-pipeline-debug` pinned to a superseded digest was the only visible workload in the
namespace two hours later, and misrepresents what dev is running.

## 2026-10-09 evening: dev done, and what is NOT in git

Dev's delivery is automated end to end: Tim pushes, his repo builds a digest to
`risingwave/poc-pipeline`, `promote.yml` writes it into `values-dev.yaml` and merges its own
PR, Argo syncs, the hook applies. Proven three times (pipeline #90, #92, #96).

**But dev's environment is not all in code.** `secrets.tf` declares only postgres, root,
svc-reporting, secret_store_private_key and console_license_key. Live dev also has
**entity, mongodb, kafka, grafana** and dex_entra_client_secret. `mongodb` and `kafka` hold
third-party credentials, so they cannot use `random_password` — they take the
`console_license_key` pattern (secret + `ignore_changes`, value set out of band) and each
needs **both** its secret and its version imported, or an apply rotates a live credential.
Also drift: the ECR repository policy and an `ecr-push` IAM statement, both added by hand.

Resume point with the full state, open PRs and ordered next steps:
`wip/onprem-app-cicd/RESUME-2026-10-09.md`. QA readiness, nine gates re-asked:
`wip/onprem-app-cicd/QA-PREFLIGHT-2026-10-09.md`.

**QA is healthier than assumed** — on the Helm chart, credential synced, applying SQL.
Its admin role `risingwave` is superuser, so the bootstrap hook needs no QA variant. Its
`wal_level` is still `replica`, and the QA half of that change is already drafted in PR #41.

## 2026-10-15 — QA joined the promotion chain, on dispatch only

`promote.yml` is the single promotion engine, and `apps.json` (repo root) is its control surface:

```json
{ "key": "risingwave-etl", "ecr": "risingwave/poc-pipeline",
  "promote": ["dev", "qa"],
  "values": { "dev": "deploy/chart/values-dev.yaml", "qa": "...values-qa.yaml",
              "prod": "...values-prod.yaml" } }
```

Each environment's source is the one before it — dev from ECR, QA from `values-dev.yaml`, prod
from `values-qa.yaml` — so nothing is rebuilt between environments and QA can only receive what
dev actually ran. **Prod opens a PR and never self-merges.**

**Doke's decision 2026-10-15: QA and prod promote on explicit dispatch only.** PR #122 added
`"qa"` to the list and gated automatic triggers to dev, because `inputs.only` is empty on every
schedule/`workflow_run` tick:

```sh
if [ "$ONLY" != "$E" ] && { [ -n "$ONLY" ] || [ "$E" != "dev" ]; }; then  # skip
```

Promote with `gh workflow run promote.yml --repo variant-inc/risingwave-pipeline -f only=qa`.
Proven live 13:26Z: `risingwave-etl/qa: already on sha256:4553550446f9 (from
deploy/chart/values-dev.yaml)`.

Side effect worth keeping: before this, one tick could carry an image ECR→dev→QA→**prod PR
opened**, with QA holding the digest for seconds (`max-parallel: 1`, each job re-checking out
master after the previous merged). A scheduled run can no longer reach prod at all.

⚠️ `promote.yml` hard-fails if a target's `values-*.yaml` does not already point at the `ecr`
repository in `apps.json`. That is why PR #119 (QA's `image.repository`) was a **prerequisite**
for enabling QA, not just a bug fix — gate 5 of [[delivery-is-a-relay-of-nine-gates]], guarded
here. PR #121 deleted the superseded `promote-to-qa.yml`
([[edited-copy-is-not-the-shipped-copy]]).

**Still open for QA** (all provisioning, no plumbing): Atlas database + user → `risingwave/mongodb`;
`entities` Postgres + `rw_entity_app` + publication + `wal_level` (PR #97 drafts the hook);
Employee Kafka topic + grant. **Prod**: the same list with nothing pre-existing, plus PR #84 for
`values-prod.yaml`. Detail: `wip/onprem-app-cicd/FINDINGS-2026-10-14-qa-first-real-run.md`.

## ⚠️ 2026-10-15 — iaac-risingwave-onprem has NEVER applied: there is no state at all

Searched **every** bucket in the dev account 700736442855 (`usx-dev` profile):

| Bucket | Keys | What it holds |
|---|---|---|
| `lazy-tf-state-65v583i6my68y6x9` | 98 | `iaac-eks/…` cloud EKS state; the 2 "risingwave" hits are `octopus/iaac/…/OnPremise.json`, config not state |
| `op-usxpress-dev-tfstate` | 27 | the **DX app platform** — attrition-api, brands-api, geoenrichment-sync-handler, io-notifications-handler |
| `usxpress-tf-state-8300lkoz74prn4fd` | 2083 | 4 risingwave hits, all `USXpress/risingwave/common/{kafka,replicator}` — a DIFFERENT project |
| `risingwave-state-op-usxpress-dev` | 160 | Hummock object store, **zero** `.tf` keys |

**No state for this module exists.** Confirms the 2026-08-12 PR #29 finding rather than
superseding it: the package never contained the Terraform, so every `dpl` deploy since June
went green without applying anything. #29 fixed the packaging; no apply has landed since.

**Consequence, and it is not small.** Dev's RisingWave estate is entirely unmanaged: the S3
bucket, the IRSA role, the five platform secrets in `secrets.tf` and the five hand-made app
secrets. A first apply would 409 on every one. So "import the five app secrets" was the wrong
size of problem — it is the whole module.

**The resolution that is also the proof:** import dev, run `terraform plan`, and **do not
apply**. A plan showing no changes proves the module's config matches a real environment —
non-destructive validation. Only then is prod safe, which keeps the promotion order
([[promotion-order-qa2-dev-qa-prod]]) intact; applying an unproven module to prod first
inverts it.

**How to apply:** before planning any Terraform work on this module, check whether state
exists at all. `aws s3 ls s3://<bucket> --recursive` per candidate bucket, and discriminate
DENIED from empty — `grep ... | head` returns 0 even with no input, so a `|| echo "none"`
after `head` never fires ([[a-guard-can-measure-the-wrong-thing]]). ⚠️ `op-*-platform-admin`
cannot `ListAllMyBuckets`, but `usx-dev` can; profile names are asymmetric and there is no
`op-dev` ([[wsl-kubeconfig-churn]]).

## 2026-10-20 — the second app, and the first one with an intake

The **pricing app** (repo in `usxpressinc`, prod 0.1.39, currently DX/Octopus → EKS) is
onboarding to on-prem, and it is the engagement that produces the reusable path —
[[onboarding-is-the-deliverable]]. **Idris owns it end to end** with Shrikant, no approval
gate. Notes:
`wip/onprem-app-cicd/MEETING-2026-10-20-pricing-app-onboarding.md`.

What was settled on the call: the repo **stays** in `usxpressinc`; on-prem pulls the app's
**existing** ECR repository; sizing is **read off the live DX prod cluster**, not asked of
the app team; `docker-compose.yml` is **not** a config source; and observability does **not**
change — which means the OTEL endpoint variables Octopus injects must be carried into the
on-prem values ([[observability-parity-is-clickhouse-not-loki]]).

⚠️ **The premise of the engagement is stale.** The app is going on-prem because a partner
endpoint (KNX) worked from on-prem and failed from cloud — measured once, months ago, by
Matt, who said so himself: *"the tests worked on-prem, but I've slept since then as well."*
Ping it from on-prem before doing the migration work, not after.

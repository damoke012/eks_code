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

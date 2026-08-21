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

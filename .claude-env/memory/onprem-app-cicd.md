---
name: onprem-app-cicd
description: On-prem app delivery path (build in GHA → ECR → Argo CD); platform + build/push proven; first deploy blocked on Argo CD having no Git credential (INFRA-1647)
metadata:
  type: project
---

Jira: epic **INFRA-1632**, stories INFRA-1633…1648, in sprint **959 "UI Sprint 3"**
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

**The current blocker: Argo CD holds NO Git credential on op-usxpress-qa** (no secret with
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

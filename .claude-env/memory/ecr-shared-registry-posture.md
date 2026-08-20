---
name: ecr-shared-registry-posture
description: "Shared ECR 064859874041 — 515 of 517 repositories grant push to every account in the org; no registry policy; on-prem insulated only by digest pinning (INFRA-1643 review, INFRA-1655 remediation)"
metadata:
  node_type: memory
  type: project
---

Swept 2026-08-20 (`scripts/audit-ecr-policies.sh --profile infra-common --region <r> --summary`).

| | us-east-2 | us-east-1 | total |
|---|---|---|---|
| repositories | 497 | 20 | **517** |
| write to org `o-yza5l1xhrc` | 495 | 20 | **515 (99.6%)** |
| read-only, correctly scoped | 1 | 0 | **1** |
| no policy at all | 1 | 0 | **1** |
| `IMMUTABLE` | 5 | 2 | **7 (1.4%)** |
| `scanOnPush` | 51 | 16 | **67 (13%)** |

⚠️ **No registry-level permissions policy** — `get-registry-policy` is empty in both regions, so
authorisation is per-repository across all 517. `describe-registry` returns *replication* config
and does not answer "who can push"; use `get-registry-policy`.

**Any principal in any account in the org can push over any mutable tag** → the same tag resolves
to different bytes on the next pull, with no deletion, no error and no event in the consuming
cluster. Scanning would not catch it (13%).

* The one read-only repo is `risingwave/etl-pipeline` — created 2026-08-20 for on-prem
  ([[onprem-app-cicd]]). The one policy-less repo is `usxpress/playright-base`, a typo beside the
  real `usxpress/playwright-base`; unreadable cross-account, never wired up, delete it.
* **On-prem is insulated only by luck**: `require-image-digest` went Enforce on op-qa app
  namespaces the same morning (INFRA-1640) for CI/CD reasons, and the path promotes by digest.
  **The EKS fleet has NO verified equivalent** and is where most of the 517 are consumed — that
  check is step (a) of INFRA-1655 and decides how urgent the rest is.
* **Nothing manages this as code.** `aws_ecr_repository` appears once in the whole org, in an
  interview sandbox. Remediation depends on the ECR Terraform bootstrap (INFRA-1651).

**Trap — how I got this wrong first.** On 2026-08-20 I recorded `lazy/api` as "a repository not
to copy policies from", from a single sample. It is the *template*, not an outlier. One
repository's policy is not the registry's posture: enumerate before characterising.
See [[adjacent-step-green-signals]] for the wider family. Review:
`wip/onprem-app-cicd/ECR-REGISTRY-REVIEW-2026-08-20.md`.

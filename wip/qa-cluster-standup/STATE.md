# QA cluster stand-up — STATE / completion tracker

**Epic:** INFRA-1560 · **Kickoff:** INFRA-1585 (In Progress) · **Automation+rebuild:** INFRA-1589 (sprint)
**Cluster:** `op-usxpress-qa` — CREATED (per 2026-07-13 standup). Remaining = codify manual steps → rebuild-to-validate → prod.

## Completion checklist

### A. iaac-talos parameterization refactor (single code path, per-env tfvars)
| Patch | What | Status |
|---|---|---|
| 01-variables-additions.tf | append new vars to variables.tf | drafted (mechanical) |
| 02-main-vsphere-worker-block | main.tf → `worker_pools` structure | drafted (manual edit) |
| 03-risingwave-2-imports-gate | gate RW-2 imports off in QA | drafted (`git mv` hack; cleanup = INFRA follow-up) |
| 04-talosconfig-secret-import | Dev ARN → `var.talosconfig_secret_arn` | drafted (manual edit) |
| **05-modules-talos-labels-taints** | **modules/talos accepts `worker_pools`, applies pool labels+taints per worker** | ⛔ **NOT DRAFTED — blocked on modules/talos/*.tf** |

Without 05, QA nodes come up sized but WITHOUT pool labels/taints → the 3-pool architecture (System/Platform/Application) doesn't actually land.

### B. INFRA-1589 — automate the manual Flux reconciliation params
Lessons-learned from the QA build: several platform-stack Flux reconciliation params were set by hand.
**NEED: the list of those manual steps** to codify them. (Unknown to me — from the QA stand-up.)

### C. Octopus vars
- `add-qa-vars.py` drafted + CLI-2.x patched — **not yet run** (adds QA-scoped Octopus vars; safe/add-only).

### D. Retest (validation gate)
1. Dev empty-diff: `terraform plan -var-file=envs/dev.tfvars` → **"No changes."** (proves refactor is semantically identical to live Dev).
2. QA dry-run: `terraform plan -var-file=envs/qa.tfvars` → all-adds, zero destroys/changes.
3. **Rebuild QA from scratch** with the codified steps → near-zero manual → sign-off → prod cluster.

### E. Follow-ups to file (from refactor README)
- op-qa flux branch scaffolding · seed `op-usxpress-qa/talosconfig` SM secret · cloud `ONPREM_BOOTSTRAP_ROLE_ARN_QA` + GHA secret · RW-2 gating cleanup (`.tf.dev-only` → for_each).

## Blockers → need from Dare (both live in the iaac-talos WSL clone, not this repo)
1. Paste `deploy/terraform/modules/talos/main.tf` + `variables.tf` → I draft **patch 05**.
2. List the **manual Flux reconciliation steps** from the QA build → I codify them for **INFRA-1589**.

## Critical path
05 (labels/taints) → apply 01–05 on a refactor branch → Dev empty-diff retest → QA dry-run → rebuild QA → prod.

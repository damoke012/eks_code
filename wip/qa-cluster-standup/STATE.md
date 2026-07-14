# QA cluster stand-up — STATE / completion tracker

**Epic:** INFRA-1560 · **Kickoff:** INFRA-1585 (In Progress) · **Automation+rebuild:** INFRA-1589 (sprint)
**Cluster:** `op-usxpress-qa` — CREATED (per 2026-07-13 standup). Remaining = codify manual steps → rebuild-to-validate → prod.

## Completion checklist

### ⚑ REALITY CHECK (2026-07-13): the refactor is ALREADY DONE in the repo
The parameterization refactor is committed on `iaac-talos` branch **`refactor/multi-env-parameterization`** (commit `5492f9b`), now merged with `feature/op-usxpress-dev` (merge `adfbed0`) and **`terraform validate` → "configuration is valid."** The real repo already has: worker_pools/enable_rw2_imports/talosconfig_secret_arn vars, `effective_worker_pools` + `worker_pool_metadata` locals (sort(keys) aligned), vsphere_worker `for_each`, talos module wired, `envs/{dev,qa}.tfvars`, RW-2 gated (`.tf.dev-only`), and the `for_each`-gated talosconfig import.
**The draft patches 01–04 below were REDUNDANT re-drafts (and had bugs: taints-as-list, obsolete patch 05). The real repo uses taints as `map(string)` and is correct. Do NOT apply them — the work exists.**
Remaining = run the plans + fill QA values (see D).

### A. iaac-talos parameterization refactor (single code path, per-env tfvars) — SUPERSEDED by repo
| Patch | What | Status |
|---|---|---|
| 01-variables-additions.tf | append new vars to variables.tf | drafted (mechanical) |
| 02-main-vsphere-worker-block | main.tf → per-pool `for_each` + build `worker_pool_metadata` + `moved` block | **CORRECTED 2026-07-13** (was buggy) |
| 03-risingwave-2-imports-gate | gate RW-2 imports off in QA | drafted (`git mv` hack; cleanup = INFRA follow-up) |
| 04-talosconfig-secret-import | Dev ARN → `var.talosconfig_secret_arn` | drafted (manual edit) |
| ~~05-modules-talos-labels-taints~~ | **OBSOLETE** — `modules/talos` ALREADY accepts `worker_pool_metadata` (list, taints as map, empty=Dev). No module change needed. | ✅ not needed |

**Key correction (2026-07-13):** `modules/talos/main.tf` already applies per-worker `nodeLabels`/`nodeTaints` from `var.worker_pool_metadata`. My old patch 02 was wrong (passed a map named `worker_pools`; module wants a flat index-aligned LIST named `worker_pool_metadata`, taints as `{key="value:Effect"}`). Patch 02 now builds that list correctly + adds a `moved` block so the singleton→for_each change doesn't destroy/recreate Dev workers (which would break the empty-diff retest).

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

## Blockers → need from Dare
1. ✅ RESOLVED — modules/talos already pool-aware; patch 02 corrected. (Was: paste module files.)
2. List the **manual Flux reconciliation steps** from the QA build → I codify them for **INFRA-1589** (still open).
3. To make patch 02's find/replace exact: paste the root `deploy/terraform/main.tf` `module "talos"` block (optional — the logic above is correct regardless).

## 2026-07-14 — QA DEPLOYED via Octopus (release .201) + first INFRA-1589 finding
- Deployed `0.1.0-refactor-multi-env-parameterization.1.201` to Octopus env `qa` (DevOps space). Auto plan+apply (no manual gate). Cluster op-usxpress-qa reconciled (nodes ~7d old — QA existed since ~Jul 7; deploy applied refactor on top).
- **Cluster HEALTHY**: 13 nodes Ready (3 CP + 5 app + 3 platform + 2 system), istio fully up (istiod Running, all istio Flux Kustomizations Ready), endpoint https://10.10.82.51:6443.
- **INFRA-1589 finding**: 3-pool SIZING correct, but pool LABELS+TAINTS only landed on `system` nodes. application + platform nodes have NO pool label, NO taint → isolation NOT enforced (istiod runs on an application node). **terraform STATE has the correct config for ALL pools** (join_workers[0]=application, [5]=platform, [8]=system all show right nodeLabels/nodeTaints) — so NOT a code bug; it's a Talos reconcile/apply gap: labels/taints not materialized onto already-joined app/platform nodes.
- NEXT: `talosctl get machineconfig` on an app node (10.10.82.138) to determine if config is pushed-but-not-reconciled vs not-pushed → fix = Talos re-register nudge OR force re-apply. Do NOT hand kubectl-label/taint (that's the manual step 1589 kills; tainting `application` would evict istiod).

## Critical path
apply 01–04 on a refactor branch → **Dev empty-diff retest** (must say "No changes"; watch for the `moved` block absorbing the vsphere_worker address change) → QA dry-run (verify pool labels/taints in machine config) → rebuild QA → prod.

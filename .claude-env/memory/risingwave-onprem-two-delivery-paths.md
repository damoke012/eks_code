---
name: risingwave-onprem-two-delivery-paths
description: iaac-risingwave-onprem delivers through TWO mechanisms on different triggers — Flux on main at 5m AND Octopus on every branch push — and BOTH its CI checks are permanent failures, so the repo has no working red/green signal at all
metadata:
  type: project
---

Measured 2026-10-08 on PR #40.

## Two delivery paths, two triggers, and only one of them is ever discussed

| Path | Trigger | Reaches |
|---|---|---|
| **Flux** | `branch: main` polled at **5 minutes**, every cluster | dev, QA **and prod** manifests |
| **Octopus** | **every branch push** — `Validate & Push to Octopus` cuts a release | the `dpl` environment, `Spaces-2` |

The Flux path is the one in every note ([[risingwave-onprem-has-no-promotion-gate]]). The
Octopus path was **unknown until a branch push cut release `0.5.8-rw-console-issuer.1.133`
and deployed it**. The repo holds Terraform as well as manifests (the Hummock bucket and
IRSA role, [[two-projects-one-resource]]), which is what Octopus deploys.

**Consequence:** "pushing a branch is safe because Flux only reconciles main" is true of Flux
and false of the repo. A push here is a deploy somewhere. Check both before calling a push
inert.

## ⛔ Both CI checks are constants, not gates

| Check | Record | Since |
|---|---|---|
| `Manifest Lint (PR Check)` → Terraform Validate | **5 failures / 5 `pull_request` runs** | 2026-09-15 |
| `dpl` Octopus deployment | **7 failures / 7 statuses, ZERO successes** | 2026-08-12 |

Every merge to `main` in that window landed over both. `infra-1693-dev-podmonitors` merged as
#38 with both red.

**Why it matters:** a check that has never passed cannot distinguish a real break from the
floor. The repo's red/green says nothing, so the only way to know whether a change worked is
to walk the Flux chain and finish at the pod. That is also why
[[server-side-apply-keeps-dropped-fields]] could freeze this very Deployment's Kustomization
for four hours unnoticed — nothing was watching, and nothing could have gone redder.

Same family as the `rw-prod-status` gate that shipped for weeks unable to return DONE:
[[adjacent-step-green-signals]], and a gate that cannot produce a pass is a constant.

## How to apply

* **Never read this repo's checks as a verdict on a change.** Compare against the population
  first: `gh api /repos/variant-inc/iaac-risingwave-onprem/commits/<sha>/statuses` across the
  last ten commits of `main`. A red check that is red everywhere is not evidence about your
  diff.
* **Verify by the Flux chain, not by CI** — GitRepository revision → Kustomization
  `lastAppliedRevision` + `Ready` → the live object's field → pod `startTime`
  ([[gitops-has-four-stale-layers]]).
* **Both red checks need their own tickets.** They are not this change's problem and they are
  not nobody's problem.

Noted in passing: `octopusworker-0` on op-dev sits at **33G/46G (72%)**, 14G free — not the
cause here, but the same growth that filled a worker at 39/40G on 2026-09-30
([[tf-plugin-cache-fills-octopus-worker]]).

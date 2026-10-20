---
name: mirror-sql-has-its-own-apply-path
description: RESOLVED 2026-10-16 (#126 guard, #127 deletion) — the mirror WAS applied by an active Pipeline Query Runner; keep the ordering lesson, a second path beside the chart
metadata:
  type: project
---

`variant-inc/risingwave-pipeline` carries a mirror of the RisingWave SQL under `pipelines/`,
and **`Pipeline Query Runner` (`pipeline.yaml`) is `active`** — it triggers on push to
`master`, `qa` or `dev` with `paths: ['pipelines/**']` and applies the changed `.sql`/`.rw`
behind a manual approval.

So SQL reaches a cluster two ways: the chart's Argo sync hook (from the `poc-pipeline` image
built from `usxpressinc/risingwave-poc`, gated by the `promote.yml` digest chain and the
`pipeline_applied` ledger), and `pipeline.yaml` reading **the mirror**. The mirror is the copy
that holds `Brand/300-transform.sql`, which the source of truth lacks.

Directory references across the six live workflows:
- `pipelines/shared` — 14 hits, from `secret.yaml` and `user-access-deploy.yaml`. **Load-bearing.**
- `pipelines/canary` — 1 hit, from `pipeline.yaml`.
- `Brand`, `employee`, `Template`, `secret_manager` — named by nothing; swept only by the glob.

**Why:** the mirror looks like dead weight in git, so "delete the duplicate" reads as a
one-commit tidy-up (INFRA-1705 words it that way, and I repeated it twice). Both readings are
wrong: `shared/` is consumed by two deployment workflows, and the rest is reachable by a live
apply workflow.

**How to apply:** narrow `pipeline.yaml`'s `paths` to `pipelines/shared/**` (or retire it)
**before** deleting anything. A commit that deletes files under `pipelines/` is itself a push
matching `pipelines/**`, and the workflow's detection is diff-based, so the deletion presents
the removed files to the thing whose job is to apply them — only the approval gate stands in
front. Same ordering shape as [[empty-value-renders-as-empty-string]]: fix the gate first,
then change the inputs. Related: [[risingwave-onprem-two-delivery-paths]],
[[edited-copy-is-not-the-shipped-copy]].

## ✅ Resolved 2026-10-16

- `risingwave-pipeline#126` excluded `Brand/`, `employee/`, `Template/`, `secret_manager/`
  from `pipeline.yaml`'s `paths` — the guard.
- `risingwave-pipeline#127` deleted them: 24 files, 1667 lines. `shared/` and `canary/` kept.
  Archived to `/tmp/rw-mirror-pipelines-2026-10-16.tar.gz` and still in git history.

`Brand/300-transform.sql`, the file INFRA-1705 was written around, turned out to be an **empty
placeholder** — "NO CODE NEEDED / This file is intentionally left blank." The ticket's premise
(QA runs a transform the source of truth lacks) was false. The real defect was the one it never
mentioned: the mirror had a live apply path.

**The lesson that outlives the fix:** change the trigger before changing the inputs. A commit
deleting files under a watched `paths:` glob is itself a push matching that glob, and
diff-based detection hands the deleted files to the workflow whose job is to apply them.

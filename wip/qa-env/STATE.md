# QA Env (risingwave-qa) — STATE
*Last updated 2026-05-27*

## STATUS: HOLD

Idris was keen to spin up `risingwave-qa` (chat: *"when I'm back I'll create the qa env"*). Doke asked him to **wait** until Dev (risingwave-2) is fully closed and the pattern is proven. QA stand-up will be done **together**, as one coordinated piece, after Dev is locked.

## Why hold
1. The pattern isn't yet end-to-end proven on Dev — full SQL run still gated on the master PR (which itself waits on Idris signoff + the tracking-table extension).
2. QA needs AWS infra via Octopus/Terraform (IAM role + S3 hummock bucket + SM seed) — Idris doesn't have Octopus access, so doing it as one coordinated pass with Doke is cleaner than splitting.
3. Kafka topic isolation for QA is an unresolved decision (separate Confluent topics vs shared with non-prod) — needs Tim's input.

## When Dev is closed, QA will need (mirror of risingwave-2)

| Piece | Owner |
|-------|-------|
| Namespace `risingwave-qa` + Flux Kustomizations (mirror risingwave-2). | Idris (Flux/k8s) |
| IAM role `gha-op-usxpress-dev-risingwave-qa-secrets` with master-only trust, SM read scoped to `risingwave-qa/*`. | **Doke (Octopus / Terraform)** |
| S3 hummock bucket `op-usxpress-dev-risingwave-qa-hummock`. | **Doke (Octopus / Terraform)** |
| SM secret seeds: `op-usxpress-dev/risingwave-qa/{postgres,root,rw-license-key}`. | **Doke (AWS CLI)** |
| RW deployment via `iaac-risingwave-2` pattern (or fork `iaac-risingwave-qa`). | Idris (Flux) |
| pipeline.yaml strategy — single repo with `qa-` prefixed dirs OR a parallel `risingwave-pipeline-qa` repo. | Decide together when we start. |
| Kafka topic isolation strategy (separate Confluent topics vs shared). | **Idris + Tim** |

## Risk / watch-outs
- **Don't let Idris run ahead** and stand up QA before Dev closes — risks divergence and rework.
- Keep this dir as the HOLD marker so any future session can see immediately "QA is paused on purpose."

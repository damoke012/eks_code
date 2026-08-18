# risingwave-pipeline scaffold — image build + Argo CD deploy

Files to add to **`variant-inc/risingwave-pipeline`** (default branch `master`) so a merge
builds an image, pushes it to ECR by digest, and Argo CD deploys it to `app-risingwave` on
op-usxpress-qa.

**This does not change the existing pipeline.** `.github/workflows/pipeline.yaml` and the
in-cluster ARC runner keep applying SQL to `risingwave-2` on op-usxpress-dev exactly as
today. This adds a second path, for QA and prod, which have no ARC runner.

## Layout

```
build/Dockerfile                     alpine + psql, copies pipelines/ and smoke/
build/apply.sh                       idempotent applier, hash-tracked in Postgres
smoke/001-connectivity.rw            trivial payload: SELECT version(); SELECT 1
.github/workflows/build-and-push.yml build -> ECR by digest -> open QA promotion PR
deploy/base/                         Job (Argo sync hook) + ExternalSecret
deploy/overlays/qa/                  digest pin, QA endpoints, QA secret paths
deploy/overlays/prod/                same, prod paths
```

## Smoke test first

`deploy/overlays/qa/endpoints.yaml` sets `PIPELINE_DIR: /pipeline/smoke`, so the first run
executes `SELECT version(); SELECT 1` and nothing else. That proves the entire chain —
build, push by digest, cross-account pull, Argo CD sync, in-cluster execution, DNS to
`risingwave-frontend`, credentials from Secrets Manager — without touching any real SQL.

Once Tim has confirmed what `pipelines/Brand/` should contain (INFRA-1644: `400-sink.rw`
defines sinks the live dev cluster does not have), change one line:

```yaml
PIPELINE_DIR: /pipeline/pipelines/Brand
```

## Verified facts this is built on (2026-08-18)

| | |
|---|---|
| ECR repository | `064859874041.dkr.ecr.us-east-2.amazonaws.com/risingwave/etl-pipeline` |
| Push role | `arn:aws:iam::064859874041:role/gha-risingwave-etl-ecr-push`, trust pinned to `refs/heads/master` |
| QA RW frontend | `risingwave-frontend.risingwave.svc.cluster.local:4567` (ClusterIP) |
| QA secrets | `op-usxpress-qa/risingwave/root` (property `password`), `op-usxpress-qa/risingwave/postgres` (`username`, `password`) |
| NetworkPolicy | none on QA — nothing blocks `app-risingwave → risingwave` |

## Before the prod overlay is used

`deploy/overlays/prod/` was derived from the QA overlay by substitution. Two things are
**unverified** on prod and must be checked before it is wired:

1. Whether a `risingwave` namespace and frontend exist on op-usxpress-prod at all.
2. Whether `op-usxpress-prod/risingwave/{root,postgres}` exist in Secrets Manager
   (account 937464026810).

Prod also has no ApplicationSet yet (INFRA-1636), so nothing consumes this overlay today.

## Why the applier refuses changed files

RisingWave has no read-write transactions, so a half-applied edit cannot be rolled back.
`apply.sh` records the sha256 of every applied file and **refuses** a file whose hash has
changed rather than re-running it. Add a new file instead. This is the RW-compatible
tracking table that `iaac-risingwave-cicd` §10 lists as an open item — Flyway was rejected
because its bookkeeping needs a transaction and types RisingWave will not accept.

## Bookkeeping lives in Postgres, not RisingWave

For the same reason: `pipeline_applied` is a normal table in the backing Postgres where an
`ON CONFLICT` upsert is safe. RisingWave also rejects `VARCHAR(N)`, so the schema uses bare
`text`.

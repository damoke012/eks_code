# iaac-risingwave-onprem #36 — console org sync + Recreate strategy

**Status: Round 1 posted 2026-09-15, awaiting Idris.**
Comment: https://github.com/variant-inc/iaac-risingwave-onprem/pull/36#issuecomment-5686295192

Author: ifagbemi-usxpress. Head `fix/console-org-sync-and-recreate-strategy` @ d8623b6, base
`main`. Files: `manifests/op-usxpress-{qa,prod}/risingwave-console.yaml`.

## The structural fact that drives everything

**op-usxpress-prod reconciles THIS repo from `main`.** `kustomization/risingwave-onprem`,
`Applied revision: main@sha1:c4b360…`, Ready, 13d, alongside `risingwave-operator` on the same
revision. So any merge to `main` here is a production deploy — no Octopus release, no approval
environment, no promotion step. `reviewDecision` on the PR is empty.

This repo therefore needs a review discipline the branch-per-env repos do not: there is no
gate between a merge and prod.

## Blockers (4)

1. Merging deploys to prod ungated, with `strategy: Recreate` killing the running pod first.
   Split the prod manifest, or state the intent explicitly.
2. `psql` without `-v ON_ERROR_STOP=1` and no transaction — a failed sync exits 0 and the
   console starts on partially synced data.
3. The guard tests `cluster_connection_info` but the SQL reads `anclax.orgs`; the test is also
   not schema-qualified.
4. QA's Prometheus endpoint names a namespace that does not exist (`monitoring`), and the PR
   deletes the TODO that flagged it.

## Advisory (4)

5. `postgres:17` unpinned from Docker Hub, on a prod pod.
6. The sync is one restart behind on a fresh environment; a skip logs the same as a success.
7. No resources; no seccompProfile.
8. `Recreate` needs a comment saying why, or someone reverts it.

## Cleared by checking, not by assuming (3)

- `sync-orgs` is an **initContainer** — lines 128 / 190 / 325. No restart loop.
- Prod has `svc/pg-postgresql` and `secret/pg-credentials` in `risingwave`.
- QA has the same, with `username` + `password` keys.

## Open question back to Doke

What was the QA symptom? The review covers whether the fix is SAFE. Whether it is the RIGHT
fix depends on what was seen, which is still unstated.

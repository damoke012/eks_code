# iaac-risingwave-onprem #36 — console org sync + Recreate strategy

**Status: ✅ APPROVED 2026-09-15 at e0d9d9f. Round 2 verified all 8 items.**
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


## Round 2 — e0d9d9f, APPROVED 2026-09-15

Idris addressed all eight. Each was verified against the branch or the live QA cluster rather
than the summary; the two claims most worth doubting both held:

- **Prometheus service exists** — `prometheus-stack-kube-prom-prometheus` in namespace
  `prometheus` on QA, ports 9090/8080. The old address named a `monitoring` namespace that does
  not exist on that cluster at all.
- **The RWO PVC is real** — `kind: PersistentVolumeClaim` (90), `accessModes:
  ["ReadWriteOnce"]` (95), `claimName: risingwave-console-data` (459). With `replicas: 1`,
  RollingUpdate would deadlock on multi-attach, so `Recreate` is required and the inline
  comment states a true reason.

Also confirmed: prod reverted out of scope (QA file only), `ON_ERROR_STOP` on all three psql
calls with `BEGIN`/`COMMIT` around **both** INSERTs, the guard schema-qualified and covering
`anclax` via `information_schema.schemata`, the tag replaced by a digest rather than appended.

Comments: round 1 `#issuecomment-5686295192`, round 2 `#issuecomment-5687097636`.

## Left open deliberately

**Advisory — a connection failure still reports as a benign skip.** `HAS_TABLES=$(psql …)`
captures output through command substitution; there is no `set -e` and the exit status is not
tested. `ON_ERROR_STOP` makes psql exit non-zero, but the script carries on with an empty
variable, the `if` matches, and it logs *"schema not yet initialized … skipping"* and exits 0.
An unreachable database is then indistinguishable from a first deploy. Same shape as the bug
the PR fixes, one layer out. Raised, not blocked on.

**The prod promotion PR still has to happen**, carrying the same eight fixes — and it needs a
reviewer, because a merge to `main` here IS a production deploy. See
[[rw-prod-blocked-on-manifests-path]].

**Never answered:** what Doke actually saw in QA. The review establishes the change is safe and
well made; that it addresses the observed symptom is still unconfirmed.

## Postscript — approved, merged, and then it did not apply (2026-09-15)

#36 merged and Flux could not apply it for ~4 hours. The live Deployment still carried
`spec.strategy.rollingUpdate`, which is Forbidden alongside `type: Recreate`, so the
server-side-apply dry-run failed and froze the whole `risingwave-onprem` Kustomization —
not just the console. Repaired by removing the field from the live object; the new template
then landed (`sync-orgs` present, pod age 118s).

**The review missed it across both rounds.** Item 8 asked *why* `Recreate`, and round 2
established the reason was sound (RWO PVC, `replicas: 1`, multi-attach deadlock). Neither
round asked the different question: **can this change apply to the object that already
exists?** That question is now a checklist item in `pr-review-rw`.

Full write-up, including the dev divergence left open and the PodSecurity warning this
surfaced: [2026-09-15-recreate-strategy-stuck-reconcile.md](2026-09-15-recreate-strategy-stuck-reconcile.md).

**#37 (`rollingUpdate: null`) is now redundant** — recommend closing rather than merging.
It fixes the manifest side of a problem that lived in the live object, it carries two
unexplained red checks, and whether `kustomize build` preserves the null was never tested.

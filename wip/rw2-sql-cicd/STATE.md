# RW-2 SQL Pipeline CICD — STATE
*Last updated 2026-05-28*

## Ownership (as of 2026-05-27 handoff)
- **Idris owns RW end-to-end going forward** — Phase 1 `risingwave` ns AND Phase 2 `risingwave-2` SQL CICD. Includes the "secrets + user creation in the Platform" work (#4 below).
- **Doke supports on the Octopus/infra side** (TfApply discipline, IAM roles via Octopus, AWS infra). Focus moves back to **networking** (see [`../onprem-networking/STATE.md`](../onprem-networking/STATE.md)).
- Handoff record: [`correspondence/idris-2026-05-27-to-28.md`](correspondence/idris-2026-05-27-to-28.md).

## Where it stands
Self-hosted ARC runner deployed in-cluster (arc-systems / arc-runners) on op-usxpress-dev. Listener pod authenticated to GitHub and long-polling for jobs. `pipeline.yaml` on branch `feat/onprem-rw2-adaptation` now runs the `execute` job on the in-cluster runner (`runs-on: risingwave-pipeline`), with `aws` CLI + `jq` installed at run-time and `psql` later in the job. Repo secrets for the in-cluster endpoints are set. Runner + in-cluster network proven green via a throwaway healthcheck workflow (run `26536028292` — runner pod spawned on-demand, TCP OPEN to both RW:4567 and postgres:5432, no NetworkPolicy in the way). Full SQL run NOT yet executed — gated by master-scoped IAM trust + Idris signoff + the tracking-table extension.

## In-flight (Idris, 2026-05-28) — `RW_SECRET_STORE_PRIVATE_KEY_HEX`

Idris is adding `RW_SECRET_STORE_PRIVATE_KEY_HEX` (the RisingWave built-in secret-manager encryption key) on **both** RW deployments. AWS SM secret created for both namespaces. Local-deploy script updated; **NOT yet applied**. Must land via GitOps, not the local-deploy script.

**Canonical repo + Flux state (verified on cluster 2026-05-28 via `kubectl -n flux-system get gitrepository -A -o wide` + `kubectl get kustomization -A`):**

| Namespace | Source-of-truth repo | Branch | Cluster reconciliation |
|-----------|---------------------|--------|------------------------|
| `risingwave-2` (Doke's IaC pattern) | `variant-inc/iaac-risingwave-2` | **`main`** | ✅ **Flux-managed.** `GitRepository iaac-risingwave-2` (Ready=True) + `Kustomization risingwave` (Ready=True, applied revision `main@225fd7a`). Idris's framing "no gitops, only manifests" was about the *repo* containing no Flux config — but the cluster reconciles from it via wiring in `iaac-talos-flux-cluster master`. |
| `risingwave` (Tim's working ns; Idris's earlier kubectl deployment) | `variant-inc/iaac-risingwave-onprem` (per Idris, confirmed 2026-05-28) | **`main`** | ❌ **NOT Flux-managed currently.** No `GitRepository` and no `Kustomization` for this repo exists on the cluster. The running pods in `risingwave` were applied **out-of-band** (Idris's local-deploy script or an earlier `kubectl apply`). The repo's `main` is the *intended* source of truth but Flux is not reading it. |

**Earlier mistakes (corrected):** I had previously pointed at `iaac-talos-flux-platform/infrastructure/risingwave/` (any branch) and `iaac-talos-flux-platform feat/risingwave-deployment`. Neither is correct. The real platform-deployment repos are `iaac-risingwave-onprem` (Idris's earlier kubectl deployment, not yet GitOps-managed) and `iaac-risingwave-2` (Doke's IaC pattern, GitOps-managed, repeatable on other clusters). `iaac-talos-flux-platform` is platform infrastructure (Istio, ESO, ARC, etc.), not the RW deployments.

**Decision (2026-05-28, Doke): Option B — anchor Tim's `risingwave` ns to GitOps as part of this work.** Three PRs total, in sequence:
1. **RW-2 env var** → PR to `iaac-risingwave-2` `main`. Self-contained, low-risk, Flux applies on next reconcile.
2. **Tim's `risingwave` env var** → PR to `iaac-risingwave-onprem` `main`. No cluster effect yet.
3. **Anchor Tim's `risingwave` ns to Flux** → PR to `iaac-talos-flux-cluster master/clusters/bm-dev/flux-system/infra.yaml` adding a `GitRepository` for `iaac-risingwave-onprem` + a `Kustomization` consuming it. Initial reconcile must use `prune: false` to avoid Flux pruning resources that exist on the cluster but not in the repo (i.e., out-of-band-applied state). Tim coordination required before this PR merges — first Flux reconcile will pod-roll `risingwave` ns.

Sub-task A in INFRA-1485 is split into A1 (RW-2 only) and A2 (Tim's `risingwave` ns env-var + Flux anchoring) to match.

## Canonical published doc
[`ONPREM_CICD.md`](https://github.com/variant-inc/risingwave-pipeline/blob/feat/onprem-rw2-adaptation/ONPREM_CICD.md) at the root of `variant-inc/risingwave-pipeline`. Source copy here: [`risingwave-pipeline-ONPREM_CICD.md`](risingwave-pipeline-ONPREM_CICD.md).

## Key links
- Branch: [`feat/onprem-rw2-adaptation`](https://github.com/variant-inc/risingwave-pipeline/tree/feat/onprem-rw2-adaptation)
- Commits: `f3c503b` (wired pipeline.yaml) · `e5fb8cf` (published ONPREM_CICD.md)
- iaac-talos PR #30 (IAM role `gha-op-usxpress-dev-risingwave-pipeline-secrets`) → merged, commit `422c627`, Octopus release 1.143 applied.
- iaac-talos-flux-platform PR #8 (ARC controller + scale set) → merged, op-dev commit `11437db`.
- iaac-talos-flux-cluster PR #4 (Kustomizations) + PR #5 (dependsOn fix) → both merged on master.
- Successful healthcheck run: https://github.com/variant-inc/risingwave-pipeline/actions/runs/26536028292

## Decisions made
- **File-change detection, NOT Flyway.** Empirically rejected: RW disallows `VARCHAR(N)` length specifiers and has no read-write transactions; Flyway's schema-history flow is incompatible.
- **Full ARC-via-Flux**, ephemeral runners, repo-scoped to `variant-inc/risingwave-pipeline`. `minRunners: 0 / maxRunners: 2`.
- **IAM trust scoped to `refs/heads/master` only** — full pipeline can only run end-to-end on master. Defense-in-depth.
- **Repo-level secrets are coordinates only** (RISINGWAVE_HOST/PORT, POSTGRES_HOST/PORT). Credentials come from AWS SM via OIDC at run time. Nothing sensitive in GitHub Secrets.
- **Isolation guarantee:** the IAM role can read `op-usxpress-dev/risingwave-2/*` only — it cannot touch Tim's `risingwave` ns `risingwave/*`.

## Open items (Jira-linked, all filed 2026-05-28)

| Item | Jira | Owner |
|------|------|-------|
| **Umbrella: Integrate Secret Management Solution with RisingWave** (rewritten) | [INFRA-1485](https://usxpress.atlassian.net/browse/INFRA-1485) | Idris |
| **A1** — Deploy `RW_SECRET_STORE_PRIVATE_KEY_HEX` on `risingwave-2` via GitOps | [INFRA-1486](https://usxpress.atlassian.net/browse/INFRA-1486) | Idris |
| **A2** — Deploy `RW_SECRET_STORE_PRIVATE_KEY_HEX` on Tim's `risingwave` ns + **anchor Tim's `risingwave` ns to Flux** (3 PRs, `prune: false`, Tim coord) | [INFRA-1487](https://usxpress.atlassian.net/browse/INFRA-1487) | Idris |
| **B** — Platform pattern for app-managed secrets + RW/postgres user creation via SQL pipeline | [INFRA-1488](https://usxpress.atlassian.net/browse/INFRA-1488) | Idris |
| Review + sign off on `feat/onprem-rw2-adaptation` + `ONPREM_CICD.md` (the gate) | [INFRA-1489](https://usxpress.atlassian.net/browse/INFRA-1489) | Idris |
| Configure GitHub Environment `pipeline-approval` + required reviewers | [INFRA-1490](https://usxpress.atlassian.net/browse/INFRA-1490) | Idris |
| Review tracking-table + apply-all bootstrap schema (RW-compatible Flyway alternative) | [INFRA-1491](https://usxpress.atlassian.net/browse/INFRA-1491) | Idris (gated on Doke drafting) |
| Tracking table + apply-all bootstrap **drafted** → pipeline.yaml | — (not yet ticketed) | **Doke** drafts → Idris reviews via INFRA-1491 |
| Repo cleanups: disable `build.yaml`; remove `runner-healthcheck.yaml` + `.runner-healthcheck` | — | Doke |
| Master PR (after Idris signoff + tracking-table + A1/A2/B) | — | Joint |
| Full SQL smoke-test on master (Tim's `CREATE SECRET dev_kafka_prefix`) | — | Joint |
| Confirm TfApply flipped back to false in Octopus (iaac-talos project) | — | Doke |
| Custom runner image (preinstall aws/jq/psql) — followup | — | Doke |
| Followup: flip `prune: true` on the `risingwave` ns Kustomization after audit cooldown (~1 week post-A2) | — | Doke (file when A2 closes) |

## Risk / watch-outs
- IAM trust master-only means the smoke-test path requires merging. Mitigation: runner+network already proven via healthcheck, so the only un-tested layer at master-merge time is OIDC→SM→psql.
- **Don't touch the `risingwave` namespace** (Tim's `risingwave` ns). Everything must stay in `risingwave-2`.
- The `Push to Octopus` (build.yaml) workflow fails on every push — noise that could mask real failures. Disable before the master PR.
- Heredocs MANGLE in Doke's WSL terminal. For multi-line content edits, use base64-blob + single-line shell commands (see ONPREM_CICD.md transfer notes).

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
- Investigated: TF state has CORRECT pool config for all pools; live app/platform nodes lack labels/taints (they also lack the `vmtoolsd` extension label CP+system have → running OLDER machine config, never re-applied). Fix = force Talos re-apply current config to app/platform. NodeLabels/NodeTaints via config; `NoSchedule` does NOT evict running pods (only blocks new).
- Hand-applied labels+taints to app/platform on 2026-07-14 to test; taints removed (premature — no workload tolerations yet). Labels left on. Correct isolation order = labels → workload nodeSelector+tolerations (Flux op-qa) → taints LAST.

## QA remaining work = TWO tracks (clarified 2026-07-14)
**Track 1 — Storage / Tier-3 — ✅ DONE 2026-07-14.** Wired via GitOps (2 commits: flux-platform op-qa `50cee8f` adds `infrastructure/local-path-storage/`; cluster-repo master `1287c9b` adds local-path-storage→rook-ceph-operator→rook-ceph-cluster Kustomizations to `clusters/op-usxpress-qa/flux-system/infra.yaml`). Result: all 4 Kustomizations Ready; local-path-provisioner Running; **Ceph HEALTH_OK** (3 mons quorum a/b/c, mgr active, **5 OSDs** up/in on application `/dev/sdb`, spread across zones a/b/c, 2.4 TiB, `replicapool` Ready, 41 pgs active+clean); SCs `local-path`+`ceph-block`+`ceph-fs`+`ceph-bucket` present. **grafana + prometheus PVCs Bound on ceph-block**; prometheus 2/2 Running. The codified local-path (Talos `/var` path + privileged ns label) worked first try — mon PVCs bound, no helper-pod denial. **NOTE:** grafana pod then hit `CreateContainerConfigError` — SEPARATE non-storage issue (missing secret/cm ref, surfaced only now that it left Pending); being diagnosed. ORIGINAL Track-1 blocker (no storage → grafana unbound) is RESOLVED.
**Track 2 — Pool isolation (INFRA-1589, not urgent):** nothing currently needs pool labels (istiod ran flat on app node; grafana blocked on storage not labels). Realize isolation in IaC later.

### RESUME HERE (storage chain — 2026-07-14 EOD)
Grafana Pending → PVC wants `ceph-block` → no storageclasses → Rook not deployed. Findings:
- op-qa branch HAS the Rook manifests (`infrastructure/rook-ceph-{operator,cluster}`, `rook-recovery-jobs`), just NOT wired (no Flux Kustomization, no rook ns). Velero IS deployed on op-qa.
- op-qa `rook-ceph-cluster/cephcluster.yaml` is ALREADY QA-correct: raw-device OSDs `deviceFilter "^sdb$"`, worker-only. Device confirmed `/dev/sdb` (app pool has the 500GB disk).
- **Prerequisite gap:** the CephCluster mons use `volumeClaimTemplate storageClassName: local-path` (20Gi), but QA has NO storageclass — so mons can't bind → Ceph won't form. Need a **`local-path` StorageClass first**.
- Minor follow-up: SM `op-usxpress-qa/talosconfig` still = literal `PLACEHOLDER` (TF didn't write real talosconfig back on apply); kubeconfig works so not blocking. File as cleanup.

**Rollout sequence to finish QA storage:** local-path Kustomization → rook-ceph-operator → rook-ceph-cluster → `ceph-block` SC → grafana binds.

### 2026-07-14 EOD — storage change set DRAFTED, ready to apply
Investigation complete. Facts established:
- **QA `infra.yaml` is missing exactly 2 Kustomizations** vs Dev: `rook-ceph-operator` + `rook-ceph-cluster`. Everything else (incl. velero/etcd-backup) already present. Both Rook manifest dirs already exist on flux-platform **op-qa** branch (operator: helmrelease+values-cm+namespace; cluster: cephcluster+storageclasses+toolbox+servicemonitor). op-qa cephcluster = QA-correct (raw OSDs `^sdb$`, worker-only) and BYTE-IDENTICAL to Dev — incl. `mon.volumeClaimTemplate storageClassName: local-path`.
- **Repo topology:** manifests live in `iaac-talos-flux-platform` (branch-per-env: op-dev/op-qa). The Flux **Kustomization CRs** live in `iaac-talos-flux-cluster` on **master**, dir-per-cluster: `clusters/{bm-dev,op-usxpress-qa,dpl,dpl2}/flux-system/infra.yaml`. QA dir already exists.
- **`local-path` is uncodified everywhere** — exists on NO flux-platform branch, not in iaac-talos IaC. Dev runs it from a MANUAL apply. The troubleshooting doc (`iaac-talos/deploy/docs/troubleshooting/02-storage/local-path-helper-pod-namespace.md`) documents the intended-but-never-merged IaC + the critical gotcha: helper pod is privileged hostPath in ns `local-path-storage`; cluster PodSecurity=restricted denies it unless ns has `pod-security.kubernetes.io/enforce: privileged` → else mons hang Pending. Since there's no canonical Dev spec, **what we author becomes the standard**; Dev backfill = INFRA-1589 follow-up.

**DRAFTED (in `wip/qa-cluster-standup/`):**
- `local-path-storage/` — full component (namespace w/ privileged label, rbac, configmap w/ Talos-safe `/var/local-path-provisioner` path, deployment `rancher/local-path-provisioner:v0.0.30`, `local-path` SC WaitForFirstConsumer, kustomization). → goes to flux-platform **op-qa** `infrastructure/local-path-storage/`.
- `qa-infra-storage-kustomizations.yaml` — the 3 Kustomizations (local-path-storage → rook-ceph-operator[dependsOn external-secrets] → rook-ceph-cluster[dependsOn operator+local-path-storage]). → append to cluster-repo `clusters/op-usxpress-qa/flux-system/infra.yaml`.
- `APPLY-qa-storage.md` — exact copy/commit/push (both repos, GitOps — push not Octopus) + reconcile/verify + rollback.

**RESUME HERE:** run `APPLY-qa-storage.md` on WSL (2 commits: flux-platform op-qa, cluster-repo master), then `flux reconcile` + watch `kubectl get sc` for `ceph-block` and grafana PVC → Bound. Then close INFRA-1585 storage track; file/advance INFRA-1589 for op-dev local-path backfill.
**(Superseded draft:** `qa-rook-ceph-additions.yaml` — earlier guess; the real op-qa cephcluster is already correct, don't use its Part B.)

## Critical path
apply 01–04 on a refactor branch → **Dev empty-diff retest** (must say "No changes"; watch for the `moved` block absorbing the vsphere_worker address change) → QA dry-run (verify pool labels/taints in machine config) → rebuild QA → prod.

---
name: risingwave-onprem
description: "RisingWave on-prem deployment — two namespaces (risingwave = Idris track, risingwave-2 = Tim/RW-2 SQL), Phase 1 handoff done"
metadata: 
  node_type: memory
  type: project
  originSessionId: 161fed6b-7af8-49e8-9abf-c06ed6494c28
  modified: 2026-08-20T20:15:00.000Z
---

## ⚠️ 2026-08-20 — the postgres tunnel has never worked, on EITHER cluster (INFRA-1654)

`ghostunnel-rw-postgres` runs `--listen=:4567` while its Service is `5432 -> targetPort 5432`,
so nothing listens where traffic arrives. Copy of the rw-sql tunnel's listen flag.
`variant-inc/iaac-risingwave-onprem`, **both** `manifests/op-usxpress-dev/ghostunnel-rw-postgres.yaml:93`
and `manifests/op-usxpress-qa/...:69`. So `rw-postgres.op-dev.usxpress.io` has resolved and
served nothing since Phase 1 closed 2026-06-01 — 11 weeks.
⚠️ Invisible because the readinessProbe is `tcpSocket: {port: status}` (ghostunnel's 9090
status listener) — it cannot see the data port. Both pods report `READY true, 0 restarts`.
**Fix needs BOTH lines**: `--listen=:5432` AND a probe on the data port; without the probe the
next copy is equally undetectable. See [[adjacent-step-green-signals]].
`rw-sql` on 4567 is fine and verified serving on QA 2026-08-20 (INFRA-1645).


## ✅ 2026-08-13 — QA RisingWave IS UP. Supersedes the 2026-08-03 block below.

Verified live on 10.10.82.51: `risingwave-operator`, `risingwave-meta-default-0`,
`risingwave-compute-default-0`, `risingwave-frontend-default-*`, `risingwave-compactor-default-*`,
`risingwave-console-*` all Running; `rw-bootstrap-root-password` + `rw-bootstrap-service-accounts`
Completed. So the CRD-ordering deadlock described below was resolved (operator present, CRs
reconciled) and the Octopus Terraform did apply — `risingwave-state-op-usxpress-qa` returns 403
(exists, caller lacks s3 perms), not 404.

⚠️ **Unexplained:** meta 238 / compute 310 / frontend 276 / compactor 313 restarts, all stable for
~30h as of 08-13. Something was crash-looping for ~2 days and the fix is undocumented. Find out
what changed before this shape is promoted to prod.

**QA RW is ROUTABLE end to end as of 2026-08-13** — PR #86 (`iaac-talos-flux-platform`, base `op-qa`)
merged: `risingwave-dashboard.op-qa.usxpress.io` → console `:8020`,
`risingwave-overview.op-qa.usxpress.io` → meta `:5691`, both `curl -sI` **200, tls=0**.
⚠️ TLS is served by the **`*.op-qa.usxpress.io` wildcard** (`wildcard-op-qa-tls`) — `shared-http` has
only wildcard servers. The two per-host Certificates in `risingwave-routes` are issued but **unused**
(they were needed on dev only because dev's hostnames were apex-level, outside `*.op-dev`). Drop them.

QA ingress topology (for external-dns targets): `istio-ingressgateway` is a **DaemonSet 10/10** in
`istio-ingress`. Platform pool = `.106` / `.139` / `.23` (talos-wk-op-qa-platform-1/2/3).
Dev's ingress targets are `.21/.22/.26/.27/.28/.178/.180` — both clusters share `10.10.82.0/24`,
so a wrong octet in a target annotation silently points one env at the other's ingress.

---

## ⛔ 2026-08-03 (HISTORICAL — see correction above) — QA RisingWave HAS NEVER DEPLOYED.

```
kustomization risingwave-onprem  11d  False
  RisingWave/risingwave/risingwave dry-run failed:
  no matches for kind "RisingWave" in version "risingwave.risingwavelabs.com/v1alpha1"
kubectl get crd | grep -c risingwave   → 0
kubectl -n risingwave get all          → No resources found
```

**Cause = the CRD-ordering deadlock, unfixed for RW.** Operator HelmRelease and the `RisingWave`
CR live in ONE Kustomization (`./manifests/op-usxpress-qa`, dependsOn cert-manager +
external-secrets). Flux dry-runs the set together → CR fails (no CRDs) → nothing applies,
**including the operator that would install the CRDs**. Deadlocked since creation. Flux orders
plain CRD manifests fine; it can NEVER order CRDs delivered by a HelmRelease (helm-controller
installs them long after the dry-run). Dev is unaffected only because its CRDs date from
2026-04-29 — dev succeeds on pre-existing cluster state, not on anything its manifests express.

**Fix = the split already proven on QA for Argo CD** ([[pr73-argocd-repo-sync-review]], 07-24):
operator/chart in its own Kustomization, workload one `dependsOn` it with `wait: true` + a
HelmRelease healthCheck. The 07-24 note literally called this "the same shape as the RisingWave
CR ordering failure" — it was known then, used as the reference case, and only Argo CD got fixed.

⚠️ **"We aligned QA and Dev for RW" is true at the repo level and false at the cluster level.**
PR #22 (tag v0.3.0, on `main`) did build the QA platform layer; Argo CD was split and rolled out
on both. None of that made the RW Kustomization reconcile. Doke asserted alignment twice on
08-03; live output settled it. **Aligned manifests ≠ reconciled cluster — check the Kustomization.**

**QA deployment branch = `main`.** Flux GitRepository `iaac-risingwave-onprem` tracks `branch:
main`. There is NO `op-qa` branch for this repo — branch-per-env is `iaac-talos-flux-platform`
only. Terraform side has no branch at all: Octopus release, environment chosen by lifecycle.

**Also live 2026-08-03:** dev operator `risingwave-operator` CrashLoopBackOff 133×, informer
caches never sync — **straight RBAC**: SA `risingwave-operator` returns `no` to `auth can-i list`
on pods, services, AND both RW CRDs. CRDs themselves are present. Dev meta 87 restarts.
**RW licence EXPIRED 2026-07-31** (JWT: iss `prod.risingwave.com`, sub
`RW_Premium_USXpress_exp_july_31_2026`, iat 07-07 → 24-day term, tier all, `cpu_core_limit: 32`).
Console still up ONLY because it hasn't restarted since 07-17 — any drain (incl. the Talos/K8s
upgrade) kills it. Renewal is Tim/RW support; ask whether any DATA-PLANE feature is licence-gated
(esp. the secret store) — if so the whole cluster is blocked, not just the console.
**No TF state in EITHER bucket** (`lazy-tf-state-425rbol87rmn6c7m` — what `.terraform` cache
points at — or `65v583i6my68y6x9`): the QA Octopus deploy has never run. PR #22 IS merged, so
the code precondition was met. Dev's bucket + IRSA role exist unmanaged → need `terraform import`.
Secret shapes for QA: `secret_store_private_key` = **256 hex chars / 128 bytes**.
⚠️ `backend-dev.hcl` must NOT be recreated — `backend-*.hcl` + `deploy.sh` were deliberately
dropped in PR #23; the blanked `main.tf` backend block is intentional (deploy.ps1 fills it).
Unrelated but broken on QA: `grafana` HelmRelease failed 26d ("context deadline exceeded").

---

RisingWave on the on-prem dev cluster (`op-usxpress-dev`). Two separate deployments/namespaces:
- **`risingwave` — TIM's namespace.** Protect-RW: Tim coordination is **mandatory** for anything touching it. (Corrected 2026-07-20: this file previously said "Idris's track", which contradicted both the WSL-verified PR #73 review of 2026-07-10 — *"destination ns=`risingwave` = Tim's. Tim coord mandatory"* — and Doke's direct statement that QA RW is "Tim's RW, not RW2". Idris is **Phase 1 platform owner of the `iaac-risingwave-onprem` repo** — a repo/code owner, NOT a namespace owner; that's the conflation that caused the error.)
- `risingwave-2` — RW-2, **dev-only** (Doke's). Not going to QA. Frontend `risingwave-frontend.risingwave-2.svc:4567`. Verify `kubectl get rw -n risingwave-2` Running=True before/after any change.

**QA (2026-07-20 decision):** QA gets **Tim's `risingwave`**, not RW-2. ⚠️ IRSA landmine — QA's provisioned bucket/role is named `risingwave_2_data` / `risingwave-data-op-usxpress-qa` (RW-2 naming), but the SA/trust for `risingwave` must be `system:serviceaccount:risingwave:risingwave`. A trust scoped to RW-2 **fails silently**. Verify before Idris's manifests land.

**INFRA-1624 review 2026-07-22 — branch `feat/qa-platform-layer` (Idris) reviewed, 3-commit fix patch produced** (`/tmp/qa-review-fixes.patch` on WSL; source files + apply script in `iaac-drafts/qa-risingwave-jul20/qa-fixes/`, commit 673eb33). Doke has **pull-only** on `variant-inc/iaac-risingwave-onprem` as `dare-x` — cannot push, must hand Idris a patch or get write access.

✅ **`terraform plan` against live QA VERIFIED:** OIDC resolves to `arn:aws:iam::527101283767:oidc-provider/d2t7d36wmf0hbm.cloudfront.net`, sub `system:serviceaccount:risingwave:risingwave`, role `op-usxpress-qa-risingwave`, bucket `risingwave-state-op-usxpress-qa` — **6 to add, 0 to destroy**. Provider pinned aws v5.100.0 (lock committed). **Do NOT apply locally — Octopus only.**

Six defects found, all fixed in the patch:
1. 🔑 **kustomize `namespace: risingwave` transformer rewrote the Velero Schedule's namespace.** Velero only watches its own ns → Schedule created, no error, **never backs up**. No clean per-resource exemption exists; it moves to `iaac-talos-flux-platform` op-qa (Doke's, NOT YET DONE). Generalise: any namespace-scoped kustomization silently captures cross-namespace CRs.
2. No PodMonitors — dev's RW was scraped by RW's *own* Prometheus via `extraScrapeConfigs`; correctly dropping that stack left nothing scraping RW. Ports: **meta 1250, frontend 8080, compute 1222, compactor 1260**. Label scheme may be `risingwave/component` OR `risingwave.risingwavelabs.com/component` (operator-version dependent) — **gate is targets UP, not manifest present**.
3. `deploy/deploy.sh` was EKS-shaped and **has never worked anywhere** (dev state bucket is empty): `aws eks update-kubeconfig` on Talos, `kubectl apply -k` (Flux's job), `-var` for undeclared vars, and **never passed `-var-file`** so tfvars were inert. Rewritten to Terraform-only.
4. Backend hardcoded to dev; now `backend-{dev,qa}.hcl` + blanked block so missing `-backend-config` fails loudly. (Workspaces DID isolate state, so this was never destructive — I overstated that initially.)
5. `s3_bucket_prefix` is the **FULL bucket name**, not a prefix — my brief's `"risingwave-state"` was wrong.
6. 1.15 MiB dev dashboard exceeded the ConfigMap limit; documented workaround was a manual Grafana UI import → dropped. Also `risingwave-user-dashboard.json` pins datasource UID `PBFA97CFB590B2093` (RW's own Grafana) — **still unfixed**.

⚠️ Octopus has **two** near-identical projects, `iaac-risingwave-onprem` and `iaac-risingwave`, both "Cloned from Default Project" — which is real and whether a QA environment/`ENVIRONMENT` var exists is **unresolved**.
Still blocking reconcile: Tim's operator chart pin + sizing (**`replicas: 1` on meta/frontend = no HA, and QA sizing propagates to prod**) + S3 retention; scope call on `rw-root-bootstrap-job` / `rw-service-accounts-bootstrap-job` (they create SQL users = app layer in Tim's ns); Doke's deploy key + `clusters/op-usxpress-qa/risingwave.yaml`.

**Phase 1 closed / handed to Tim:** SecretsManager seeding done (ARNs captured), ExternalSecret deployed, IaC artifacts produced. External access originally pivoted LoadBalancer → NodePort; now reachable via the Istio TCP/SNI ingress (see [[onprem-networking-ingress]]). Frontend port 4567; IRSA verified via env+debug pod.

**Authoritative docs (working tree on `main`):**
- `docs/architecture/historical/risingwave_phase1_closeout_and_tim_handoff.md` — Phase 1 closeout + Tim handoff
- `docs/architecture/risingwave_onprem_platform.md`, `docs/architecture/risingwave_repo_structure_guide.md`
- `wip/rw2-sql-cicd/` — RW-2 SQL CI/CD (operational notes, pipeline, progress log)

Any PR touching RW namespaces → use the `/pr-review-rw` skill (protect-RW workflow). Related: [[repo-branch-topology-recovery]].

**Octopus deploy path FIXED 2026-07-23 (INFRA-1624).** Root cause of "nothing applies this Terraform": the `iaac-risingwave-onprem` Octopus project (`Projects-10241`) was an unconfigured clone — lifecycle `devops-auto` (single `devops` phase, no qa) and **zero variables**. Its deploy step runs `deploy.ps1`, but the repo only had `deploy.sh` (the step called a file that didn't exist). CI already fine — `.github/workflows/octo.yaml` packages `deploy/` and pushes a release on every branch push, same as iaac-talos.
Fix (all on branch `fix/qa-review` → PR #23, commit 047e712, + Octopus API):
- Added slim `deploy/deploy.ps1` — generic Terraform core copied from iaac-talos's, but WITHOUT its Talos-specific pre-destroy cluster-drain and post-apply SSM `/clusters/<name>/endpoint` validation (those would fail every RW apply).
- **Platform-standard variable model** (not `-var-file`): `TF_VAR_*` from Octopus exported as env vars, backend via `S3_BUCKET`/`TF_STATE_KEY`/`AWS_DEFAULT_REGION` flags, apply/destroy gated on `TfApply`/`TfDestroy`. So the committed `backend-*.hcl`, `op-usxpress-qa.tfvars`, and `deploy.sh` were DROPPED (my earlier `-var-file` approach in #23 was non-standard); the blanked `main.tf` backend block stays (deploy.ps1 fills it via flags).
- **`aws_profile` landmine**: `main.tf` provider had `profile = var.aws_profile` with no default → fails on the Octopus worker (role auth, no named profile). Fixed: `variables.tf` `default = null` + provider `profile = var.aws_profile != "" ? var.aws_profile : null`. Local runs still pass `-var aws_profile=usx-qa`.
- Octopus project (via `wip/qa-cluster-standup/octopus-qa-env-setup/setup-octopus-rw.py --apply`): lifecycle `Lifecycles-22`→`Lifecycles-42` (iaac-release, has qa=`Environments-602`), + 11 QA-scoped vars. Backup `/tmp/octopus-rw-backup-*.json`.
⚠️ **`TfApply=true` is QA-scoped** — a QA deploy applies for real, no plan gate. First deploy: merge #23→#22→main FIRST (don't deploy an unmerged branch), then watch the Octopus task log to confirm deploy.ps1 runs + TF_VAR_* land + worker role authenticates. First apply = 20 creates / 0 destroys (proven locally). Diff tool: `inspect-octopus-projects.py`.


## `risingwave-2` is DEV-ONLY. It is never promoted. (stated 2026-09-01)

`risingwave-2` exists on op-usxpress-dev only, for our own platform work. It is **not** a
second environment tier and it does **not** follow dev -> QA -> prod. QA and prod have
`risingwave` and nothing else.

Verified in Secrets Manager 2026-09-01:

| | `<env>/risingwave/*` | `<env>/risingwave-2/*` |
|---|---|---|
| dev `700736442855` | EXISTS | EXISTS |
| qa `527101283767` | EXISTS | **absent** |
| prod `937464026810` | absent (Terraform not yet run) | **absent** |

**Why:** any change that parameterises a `risingwave-2` path by environment is wrong on its
face — `op-usxpress-qa/risingwave-2/...` and `op-usxpress-prod/risingwave-2/...` are not
values that should ever be constructed. In `risingwave-pipeline` PR #19 an `${ENV}`
substitution produced exactly those, which would fail on the first QA run.

**How to apply:** when a workflow or manifest names a RisingWave namespace, dev may be
`risingwave-2`; **QA and prod are always `risingwave`**. Map it per environment alongside the
account id; never interpolate the namespace segment. Do not ask which namespace QA or prod
should use — the answer is `risingwave`. Related: [[onprem-gitops-repo-topology]],
[[rw-prod-blocked-on-manifests-path]].

**2026-09-01 — the RisingWave Console licence has NEVER been real, in any environment.**
`console_license_key` in BOTH `op-usxpress-qa` and `op-usxpress-prod` Secrets Manager
holds the identical 52-character placeholder JSON that Terraform generates (`{"R…`,
single part — a real licence is a compact JWT: three dot-separated parts, `eyJ` prefix).
The prod console rejects it at startup with
`license verification failed: license must be a compact JWT`.

This corrects the standing assumption that prod merely needed a value QA already had.
It is not a prod gap and there is nothing to copy — it is an outstanding vendor item for
the whole on-prem estate. Ask Steve/Zach for ONE licence covering dev/QA/prod, not a
prod-specific key.

**Open question, answer when op-qa is reachable:** is QA's `risingwave-console` pod
actually running? If it is, the licence is not required for QA's console version and only
prod's is gated; if it is crashlooping too, it has been broken since QA stood up and
nothing alerted, because the ExternalSecret is green either way
([[eso-secretsynced-not-content-check]]).

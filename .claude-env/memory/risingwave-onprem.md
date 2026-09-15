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


## ⛔ SUPERSEDED 2026-09-15 — `risingwave-2` is being DELETED. See the decommission block at the end.
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

**2026-09-01 — no environment currently holds a real Console licence.**
(Corrected in place: an earlier line here said it had "NEVER been real anywhere". The
evidence shows only that both hold the placeholder NOW —
`REQUESTS-PROD-LONG-POLES.md` records the licence as *lapsed*, i.e. there was one once.)
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

**Two different consumers of one key — do not conflate them.**
1. **`CREATE SECRET`**, the premium SQL feature. Deliberately OFF the critical path per
   `WRITEUP-FOR-IDRIS-2026-08-31.md` §4: ship apply-time substitution, convert later.
   Tim's 44 SQL files use zero `secret <name>` references. That decision is untouched by
   the console failure.
2. **The Console binary**, which refuses to start without a compact JWT.

The placeholder is the literal `PLACEHOLDER_INJECT_REAL_LICENSE` — 31 chars, inside
`{"RW_LICENSE_KEY": ...}` (52 chars of JSON), written by Terraform with `ignore_changes`
so it is never touched again.

**Correction to "console-only":** the console failing ALSO leaves
`rw-bootstrap-service-accounts` in permanent CrashLoopBackOff — it completes every group,
user and grant, then dies reconciling console UI ownership against `anclax.users`, a
schema only the console creates. The users and grants DO get applied; what you get is a
permanently red Job, not a missing service account.

## ⛔ CORRECTED SAME DAY — see the 2026-09-15 (late) block at the end of this file.
## ✅ 2026-09-15 — settled by SQL: dev's pipeline target `risingwave-2` is EMPTY

`risingwave-pipeline`'s `pipeline.yaml` maps dev -> `risingwave-2`. Challenged on 2026-09-15
("it's supposed to be the RW namespace, we use RW-2 for platform"). The mapping is **correct**
and must not be changed. Two independent proofs, neither of them anyone's recollection:

1. **Object inventory over `rw_catalog`, both dev instances, same session:**

| namespace | sources | MVs | sinks |
|---|---|---|---|
| `risingwave` | `brand_source_kafka` | `brand_mv_raw`, `brand_mv_state`, `brand_mv_flat` | none |
| `risingwave-2` | **none** | **none** | **none** |

2. **Namespace ages arithmetic to the May record.** `risingwave` 138d -> created ~2026-04-30;
   `wip/rw2-sql-cicd/risingwave_2_progress_log.md` on 2026-05-26 records "Tim's `risingwave` ns
   RUNNING=True, **26d**, completely untouched" -> ~2026-04-30. Same namespace.
   `risingwave-2` 111d -> ~2026-05-27, the day after that log created it.

**So the four Brand objects on dev are TIM's**, built by hand from the `CREATE SOURCE` pattern he
shared in Teams on 2026-05-26 — not pipeline output. `risingwave-2` is empty because the pipeline
has **never completed a run** (three runs ever, all on master, all failed at "Pull Postgres
credentials"), not because it is pointed at the wrong place.

⛔ **Repointing dev to `risingwave` would put Tim's working objects inside the blast radius of
every merge to `dev`** — the workflow issues DROP and CREATE. Protect-RW applies: that namespace
is Tim's and coordination is mandatory. See [[two-gha-roles-one-pipeline-repo]].

⚠️ **The naming is the trap, and it is permanent.** dev's platform instance is `risingwave-2`;
QA's and prod's are `risingwave`. So the role named **poc** (grants `.../risingwave/*`) is the one
QA and prod's *platform* pipeline must assume, and the role named **pipeline**
(grants `.../risingwave-2/*`) is dev-only. The names mean the opposite of what they read like.
Anyone "tidying" this will break QA.

🔴 **Real gap this exposed: dev is not a rehearsal environment for QA.** The platform instance on
dev has zero sources, MVs and sinks, and `op-usxpress-dev/risingwave-2/*` holds only postgres,
root, console_license_key and secret_store_private_key — **no kafka, no mongodb**. So a pipeline
change cannot be proven on dev before it reaches QA today. Closing that needs the Kafka
credential at `op-usxpress-dev/risingwave-2/kafka` and one successful dev run.


## ✅ 2026-09-15 (late) — Idris settled it: the pipeline belongs on `risingwave` in dev too

Asked directly, "should the pipeline be RW or RW-2?" — **"rw. rw-2 is ours."**

This CORRECTS the block above, which read the empty `risingwave-2` as "the pipeline has
simply never run" and concluded the mapping was fine. The inventory was right; the
conclusion drawn from it was wrong.

**The axis is purpose, not ownership.** `risingwave` on op-usxpress-dev is the
APPLICATION's dev environment — it is where Tim's SQL pipeline, the thing under test,
actually runs, and it holds the only Brand objects that exist on dev. `risingwave-2` was
stood up 2026-05-27 as the PLATFORM team's sandbox, created precisely so our CI/CD work
could not disturb Tim's. Pointing the application's own pipeline into our sandbox
inverted that: it protected Tim from the pipeline that is supposed to drive his objects.

⚠️ **The reasoning trap, worth more than the fact.** "That namespace is Tim's, so keep
the pipeline out of it" is protective instinct applied one level too high. Tim owns the
namespace; the pipeline is how his SQL gets deployed INTO it. Blast-radius caution about
DROP/CREATE is right for a namespace we are not deploying to, and exactly backwards for
the one we are. Ask *what is this namespace for*, not *whose is it*, before concluding.

**Two changes, not one — and only the first is in code:**
1. `pipeline.yaml` — `RW_NS` and `ROLE_KIND` become constants (`risingwave` / `poc`) and
   leave the case statement, which now sets only `AWS_ACCOUNT_ID`. A constant that cannot
   be set per environment cannot drift per environment.
   `scripts/patch-rw-pipeline-dev-namespace.py`.
2. `RISINGWAVE_HOST` / `RISINGWAVE_PORT` on the GitHub **`dev` environment**, documented
   in `wip/rw2-sql-cicd/risingwave-pipeline-ONPREM_CICD.md:189` as
   `risingwave-frontend.risingwave-2.svc.cluster.local`. **RW_NS does not decide where
   psql connects** — it selects the Secrets Manager path and the OIDC role only. Ship
   only #1 and the job reads Tim's credentials and applies them to our empty instance.

The `risingwave-2` platform sandbox is unaffected and stays. What changes is that the
application pipeline stops targeting it.


## ⛔ 2026-09-15 — `risingwave-2` is being retired. Everything becomes `risingwave`.

Doke's decision, stated plainly: "Forget RW-2 exists, it would be deleted, all should be RW
only." So the dev cluster stops running two RisingWave instances, and every environment --
dev, QA, prod -- has exactly one, named `risingwave`. This supersedes the 2026-09-01 block
above, which described `risingwave-2` as a permanent dev-only fixture.

**The trap that makes this dangerous, and it is not hypothetical.** Some AWS objects are
NAMED for risingwave-2 but SERVE `risingwave`, on QA and prod. A sweep that deletes by name
destroys the live object store:

| Name | What it actually is | Action |
|---|---|---|
| `op-usxpress-dev/risingwave-2/*` (SM) | the dev RW-2 instance's own secrets | delete with the instance |
| `op-usxpress-dev-risingwave-2` / `-s3` | the dev RW-2 bucket + old managed policy | delete with the instance |
| `gha-op-usxpress-dev-risingwave-pipeline-secrets` | grants `.../risingwave-2/*` only | dead once the pipeline moves; delete last |
| `gha-op-usxpress-qa-risingwave-pipeline-secrets` | same shape, QA | never used by anything after the move |
| **`risingwave-data-op-usxpress-{qa,prod}`** | **Hummock object store for `risingwave`** | ⛔ **RENAME AT MOST. Deleting these destroys live QA/prod data.** |
| **`risingwave_2_data`** | a Terraform module/variable name used in ALL envs | ⛔ identifier only — rename is a state migration, not a delete |

See [[two-projects-one-resource]]: `iaac-talos` and `iaac-risingwave-onprem` both declare
RisingWave's bucket and IRSA role, so a destroy in the wrong project takes the object store
with it.

⚠️ **Find out what else is squatting in the namespace before deleting it.** `risingwave-2`
holds at least a `prometheus-server` (CrashLoopBackOff, 1566 restarts as of the dev triage) --
platform monitoring living inside what everyone calls a RisingWave namespace. Enumerate the
namespace, do not assume it contains only RisingWave.

**Repos that name it** (from the RW-2 CI/CD notes, as a map of where to look):
`variant-inc/risingwave-pipeline`, `iaac-talos`, `iaac-talos-flux-platform`,
`iaac-talos-flux-cluster`, `iaac-risingwave-onprem`, `iaac-risingwave-2`,
`iaac-risingwave-cicd`.

First step is already done: `scripts/patch-rw-pipeline-dev-namespace.py` takes `RW_NS` and
`ROLE_KIND` out of the pipeline's case statement entirely, so the workflow has no way to
name `risingwave-2` again.

## ✅ 2026-09-15 — the dev SQL pipeline runs END TO END for the first time

`variant-inc/risingwave-pipeline`, branch `dev`: runs 34978761027 (.sql leg) and 34979510993
(.rw leg). validate, approve, OIDC, caller identity, both Secrets Manager reads, and BOTH
executor legs green. Four months after the fork, the first completed runs in the repo's history.

Five defects, all in one workflow file, all invisible to review — PRs #33, #35, #38, #42:

1. `on: push` listed `master` only, so merges to `qa` and `dev` triggered nothing.
2. `role-to-assume` was hardcoded to the DEV account, so a qa run reached into 700736442855.
3. `aws_role` was computed, published as a job output, and read by nobody.
4. dev's `RW_NS` pointed at `risingwave-2`, the platform sandbox, not the application's env.
5. `execute` declared no `environment:`, so its OIDC subject lacked the `environment:<name>`
   claim every poc role trusts — and environment-scoped secrets silently resolved to empty.

Then two stale values on the GitHub `dev` environment, `POSTGRES_PORT` and `RISINGWAVE_PORT`,
both from the `risingwave-2` era. See [[masked-secret-reads-as-network-fault]].

**Proven:** the runner in `arc-systems` reaches `postgres-postgresql.risingwave.svc:5432` and
`risingwave-frontend.risingwave.svc:4567`, authenticating with credentials pulled from
`op-usxpress-dev/risingwave/{postgres,root}`.

**NOT proven — do not report the pipeline as ready:**
- **DDL is completely untested.** Both checks are read-only `SELECT`s in
  `pipelines/_connectivity/`. Nothing has created, altered or dropped an object, and promotion
  depends on DDL.
- **QA has never run.** Every fix is on the `qa` branch, but QA's coordinates differ — external
  `rw-sql.op-qa.usxpress.io`, NodePort 32567, not in-cluster DNS.

⛔ **`pipeline-approval` has `protection_rules: []`** — no required reviewers, no wait timer.
The approve job prints a message and proceeds; it passed in 3-5s on every run. So a merge to
`qa` executes SQL against QA with no human gate, and prod will behave identically. Fix before
the first real promotion.

## ✅ 2026-09-15 (later) — the approval gate now EXISTS, and self-approval is deliberate

Supersedes the ⛔ block above: `pipeline-approval` no longer has `protection_rules: []`.

Set via the API, not the UI:
`PUT /repos/variant-inc/risingwave-pipeline/environments/pipeline-approval` with
`{wait_timer:0, prevent_self_review:false, reviewers:[{type:"User", id:<dare-x>}]}`.

⚠️ **`prevent_self_review: false` is INTENTIONAL and TEMPORARY** — Doke's call, so the person
who raises a change can approve it while the pipeline is still being stood up. Flipping that
one flag to `true` makes it a real second pair of eyes and changes nothing else. Nobody should
read the current state as "approvals are reviewed".

**Proven in BOTH directions on run 34981503792 — a settings page cannot show either:**
- BLOCKS: validate green in 6s, `approve` pending, `execute` never started. Before the change
  `approve` completed in 3s and the run went straight through.
- RELEASES: approving via
  `POST /actions/runs/<id>/pending_deployments {environment_ids:[20649230238], state:"approved"}`
  let it proceed and finish green. Self-approval by the same account that pushed, which also
  confirms `prevent_self_review: false` behaves as set.

⛔ **Boundaries — partial coverage feels like protection, so state them out loud:**
1. **ONE environment covers all three tiers.** The `approve` job names `pipeline-approval`
   regardless of branch, so dev, qa and prod share one gate and one reviewer list. Prod cannot
   have stricter reviewers than dev without splitting this into per-environment gates. That is
   a design limit of the workflow, not of the setting.
2. **`secret.yaml` is NOT covered.** The Secret Manager workflow has its own trigger and never
   passes through `approve`. SQL deployment is gated; secret creation is not. Do not say "the
   pipeline requires approval" without that caveat.
3. One reviewer only (`dare-x`). Idris is not on the list and should be before QA promotion.

Method note: verified by triggering a run and watching it stop, per [[authoring-gate-hooks]] --
"verify by running it, not by merging it". The API returning the rule proves registration, not
that the gate blocks.


## 🔴→✅ 2026-09-15 — dev RisingWave was storage-dead for 54 days. Fixed by one pod restart.

`risingwave-compactor-default` on op-usxpress-dev had NO AWS credentials — the IRSA webhook
never injected them at pod creation and `failurePolicy: Ignore` meant nothing said so. Hummock
compaction was therefore dead since ~2026-07-23: L0 stuck at 359 SSTs, no epoch could commit,
and every `CREATE TABLE` hung at 0.0% forever. Meta, compute and frontend all HAD credentials —
only the compactor was affected, and that was enough to freeze the instance.

Everything reported healthy the whole time: 4/4 workers RUNNING, pods 1/1, no alerts.

Fixed with `rollout restart deployment risingwave-compactor-default`; `CREATE TABLE` then
succeeded in seconds. Full mechanism in [[irsa-webhook-fails-open-at-pod-creation]].

⚠️ **Check QA and prod before their compactors next restart.** Same operator, same webhook,
same `failurePolicy: Ignore`. A compactor recreated during any webhook blip on either cluster
produces this identical silent outage, and QA is where the Brand demo runs.

⚠️ Tim's four Brand objects (`brand_source_kafka`, `brand_mv_raw/state/flat`) were frozen at a
July epoch this entire time. They are in the catalog but processed nothing for 54 days — worth
telling him rather than letting him discover stale data.

## ✅ 2026-09-15 (end of day) — DDL PROVEN through the pipeline on dev

Run 34993084502, branch `dev`, all green including `Refuse test fixtures on production` (which
correctly ALLOWED on dev — the guard's wiring proven, not just its logic). Confirmed by
catalog, not by a green step: `ddl_probe_mv` exists in schema `pipeline_canary`.

So the full chain is proven on dev: push trigger -> env-detect -> prod fixture guard -> SQL
guardrails -> approval gate -> OIDC with the environment claim -> the computed poc role ->
Secrets Manager -> in-cluster connection -> CREATE SCHEMA/TABLE/INSERT/MATERIALIZED VIEW.

**Still NOT proven, and the order matters:**
1. **QA has never run.** Every fix is on the `qa` branch but no QA run exists. QA's coordinates
   differ — external `rw-sql.op-qa.usxpress.io`, NodePort 32567, not in-cluster DNS — so its
   first run exercises a path dev did not.
2. **QA and prod compactors** may carry the same missing-IRSA fault, silently. Check before the
   Brand demo: [[irsa-webhook-fails-open-at-pod-creation]].
3. `CREATE SOURCE` is untested anywhere — it needs live Kafka credentials and a topic, and it
   is what the Brand pipeline actually does first.

Cleanup owed on dev: `pipeline_canary` schema and its two objects, plus
`pipelines/_connectivity/` on the `dev` branch, once QA is proven and they are no longer the
reference for what a working run looks like.

## ✅ 2026-09-15 — QA PROVEN (RisingWave leg). First QA run in the repo's history.

Run 34994175151, branch `qa`, green: OIDC with the `environment:qa` claim, the qa poc role,
both Secrets Manager reads, and `Execute RW files` across QA's own path — out of the **dev**
cluster (where the ARC runner lives), over `rw-sql.op-qa.usxpress.io`, back in on NodePort
**32567**. Confirmed by catalog: `pipeline_canary.ddl_probe_mv` exists on QA.

✅ **QA's compactor HAS IRSA**, as do meta, compute and frontend. So the 54-day dev outage
([[irsa-webhook-fails-open-at-pod-creation]]) is dev-only. **Prod is still unchecked.**

🔴 **QA's `.sql` leg CANNOT RUN — no external route to Postgres.** QA has `pg-postgresql` as a
ClusterIP and `ghostunnel-rw-postgres` as a ClusterIP; there is **no NodePort for Postgres**,
unlike `risingwave-frontend-ext`. That is why the `qa` GitHub environment has only
`RISINGWAVE_HOST` and `RISINGWAVE_PORT` and no `POSTGRES_*` — the value could not have existed.

**This blocks the real Brand promotion, not just the canary**: `pipelines/Brand/300-transform.sql`
is a `.sql` file, and every `.sql` file runs against Postgres. Two ways out:
1. Fix `ghostunnel-rw-postgres` — it listens on `:4567` while its Service maps 5432
   (INFRA-1654, unfixed since June), AND add a probe on the data port, or the next copy is
   equally undetectable. See the 2026-08-20 block above.
2. Add a Postgres NodePort mirroring `risingwave-frontend-ext`.

⚠️ Note the QA service is named `pg-postgresql`; dev has BOTH `pg-postgresql` and
`postgres-postgresql` as two Services over one pod. Do not copy dev's host value to QA.

## ✅ 2026-09-15 — an empty change set no longer looks like a deploy

Third control added to `pipeline.yaml`, alongside the approval gate and the prod fixture
guard. Two faults shared one symptom:

1. The changed-files step ends every branch with `|| true`, so a `git diff` that FAILS —
   empty `github.event.before`, a force-push, a base commit absent from the checkout —
   produced an EMPTY list rather than an error. "Could not determine what changed" became
   "nothing changed", and the run went green.
2. An empty set still ran `execute`: credentials pulled, psql installed, both apply steps
   silently skipped, success reported. **That exact shape was used earlier the same day as
   proof the pipeline worked** — it proved only that the steps BEFORE the apply worked.

Fix: a `Verify change detection ran` step that fails CLOSED when detection cannot have run,
and `if: needs.validate.outputs.changed_count != '0'` on BOTH `approve` and `execute`.

✅ Proven by running it, run 35000081648 on dev: validate green with the notice, approve and
execute both **skipped**, no human involved. The first attempt gated only `execute`, which
left every README change parked on a required reviewer — caught by running it, not reviewing
it. See [[authoring-gate-hooks]].

⚠️ **Patch-script trap, worth more than the fix.** `patch-rw-pipeline-approve-gate.py` had a
replacement that BEGAN with the same three lines it anchored on, so the anchor survived its
own substitution and a second run applied the block twice — duplicate `if:` keys, invalid
YAML. An anchor that survives its own replacement is not an anchor. Every patch script here
should either consume its anchor or check for its own marker first.

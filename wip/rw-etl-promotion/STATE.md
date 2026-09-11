# INFRA-1674 — RisingWave on op-usxpress-prod — state at 2026-09-01

**One action remains: create a release and deploy to `production`.**
Everything else is merged, live, or staged behind it.

Octopus prod variables written and verified 2026-09-01 — 10 production-scoped entries on
`Projects-10241`. `TfApply` deliberately NOT among them, so the first prod deploy is
plan-only on its own.

## Done and live

| | |
|---|---|
| `manifests/op-usxpress-prod/` (24 files) | `iaac-risingwave-onprem` #32, merged |
| Unconditional `import` blocks removed from `secrets.tf` | #31, merged |
| Prod routes corrected (were dev copies), `tcp-passthrough` Gateway, Velero metastore Schedule | `iaac-talos-flux-platform` #143, merged into `op-prod` and reconciled at `7f0d3b7` |
| `op-usxpress-prod/risingwave/dex_entra_client_secret` | created by hand 2026-09-01, 40 chars, verified against QA's value |

## Staged, waiting on the deploy

`scripts/wire-prod-risingwave.py` + `wip/rw-etl-promotion/prod-infra-risingwave-block.yaml`
append the GitRepository and three Kustomizations (`risingwave-operator`,
`risingwave-onprem`, `risingwave-routes`) to prod's `infra.yaml`, and rewrite the
"deliberately absent" header note rather than deleting it.

It **refuses** until all six secrets, the IRSA role and the bucket exist. Verified
refusing 2026-09-01 with 5 secrets + role + bucket missing.

## Preflight — all green 2026-09-01

| Gate | Result |
|---|---|
| Release built from current main | `0.5.4`, assembled 18:26, **package `0.5.4`** |
| Production variables | 10, verified on read-back |
| Lifecycle reaches production | `iaac-release` (Lifecycles-42) has a production phase |
| `TfApply` armed for prod? | **No** — first prod deploy is plan-only |
| Worker pool | `WORKER_POOL [production] = WorkerPools-1582` = `usxpress-production`, 2/2 healthy |

**Do not promote release `0.5.3`.** It selects package `0.5.1` from 2026-08-12, which
predates both the prod manifests and the import-block removal. Its version and package
version differ — that inequality is the tell.

**Why `0.5.4` had to be forced.** The releases are cut by `octo.yaml` on push, and the
version comes from **conventional commit prefixes**. Both INFRA-1674 merges used
`INFRA-1674: ...`, so no bump, no package, and the run still reported success plus
"Create/Update Release complete" while updating `0.5.3` in place. `fix: remove the empty
s3.tf` produced `0.5.4`. See [[conventional-commits-drive-releases]].

The `dpl` deployment failures (branch pushes and 0.5.4) are `WorkerPools-286` having
0/0 workers. Not ours, not related.

## The deploy

Octopus project `iaac-risingwave-onprem`, new prod environment:

    TF_VAR_cluster_name      op-usxpress-prod
    TF_VAR_oidc_issuer       d3rxit8f4yvshu
    TF_VAR_s3_bucket_prefix  risingwave-state-op-usxpress-prod
    S3_BUCKET / TF_STATE_KEY prod state, prod-specific key
    TfApply                  true

**Green is not applied.** `deploy.ps1` gates apply on `TfApply` and a skipped apply still
reports Success. The proof is `terraform_outputs.yml` attached as an Octopus artifact —
it is written only on the apply branch.

## Then

1. `wire-prod-risingwave.py ... --write`, PR to `iaac-talos-flux-cluster` master
2. Merge; Flux brings up the operator, the RisingWave CR and the routes
3. DNS appears on its own — external-dns writes it from the VirtualService annotations
4. Real licence into `console_license_key` (Steve/Zach) — console only

## Open, not blocking

- **Velero backup on prod** — Schedule is Enabled; confirm a real backup ~6h after
  2026-09-01 morning. The object existing proves nothing.
- **Next QA Terraform plan** — the check #31 skipped. "No changes" means the import-block
  removal was safe; wanting to create the five secrets means revert before any apply.
- **`risingwave-pipeline` #19** — one change requested (`RW_NS` mapped per environment,
  since `risingwave-2` is dev-only). Approve when it lands.
- **#18** — 112 files under a title about one ARN; asked Idris to split or close.
- **Prod Grafana VirtualService** still publishes `grafana.op-dev.usxpress.io`.
- **Entra redirect URI** for prod's callback — console, not yet done.
- **Revoke**: the Atlassian API token and both Confluent credential pairs. Still live.
- **Job 130 wedged on op-dev** — needs Tim's call on `RECOVER`.

## 2026-09-01 — release 0.5.6 deployed to production, FAILED at terraform init (403)

Release `0.5.6` (channel `release`, pins package `0.5.5`) reached the production worker and
died reading state: `S3_BUCKET` in production scope was **QA's** bucket
`lazy-tf-state-425rbol87rmn6c7m`. Prod's is `lazy-tf-state-ipp58n854uhpw13x`. Plan-only run,
nothing created. Full write-up + why two of my own checks passed over it:
`PROD-DEPLOY-403-2026-09-01.md`. Fix is in `scripts/setup-octopus-rw-prod.py` (`--fix`).
Release 0.5.6 is still good — re-deploy it after the variable is corrected.

## 2026-09-01 19:35 — PROD TERRAFORM APPLIED (INFRA-1674)

Release `0.5.6` -> `production`, `TfApply=true` armed for the one run then disarmed.
`Apply complete! Resources: 20 added, 0 changed, 0 destroyed.` Artifact
`terraform_outputs.yml` uploaded — that, not the green task, is the proof it applied.

Created in 937464026810 / us-east-2:
- `arn:aws:iam::937464026810:role/op-usxpress-prod-risingwave` (IRSA, trust on
  `d3rxit8f4yvshu.cloudfront.net`) + inline policy `risingwave-s3-access`
- `s3://risingwave-state-op-usxpress-prod` — versioning, SSE, public-access-block on
- five Secrets Manager secrets + versions under `op-usxpress-prod/risingwave/`:
  `root`, `postgres`, `svc-reporting`, `secret_store_private_key`, `console_license_key`

Two failed runs preceded it, both `403 HeadObject`: `S3_BUCKET` in production scope held
QA's bucket, and after correcting it the release still deployed its FROZEN snapshot. See
`PROD-DEPLOY-403-2026-09-01.md` and [[octopus-release-freezes-variables]].

**Next:** wire Flux (`scripts/wire-prod-risingwave.py --write` -> PR to
`iaac-talos-flux-cluster` master). **Still placeholder content:** `console_license_key`
holds a generated value, not the real licence (Steve/Zach). A green ExternalSecret will
not tell you that.

## 2026-09-01 ~19:55 — RisingWave RUNNING on op-usxpress-prod; one blocker left

PR variant-inc/iaac-talos-flux-cluster#38 merged. Flux applied
`master@sha1:33efcd97`. `RisingWave/risingwave/risingwave` reports RUNNING=True,
v2.8.2, PostgreSQL metastore + S3 state store. meta/compute/frontend/compactor,
both ghostunnels and pg-postgresql all 1/1. All seven ExternalSecrets SecretSynced.
`risingwave-routes` applied `op-prod@sha1:7f0d3b7`.

**Blocker: the console licence.** `console_license_key` holds the value Terraform
generated. The console rejects it — `license verification failed: license must be a
compact JWT` — so `risingwave-console` crashloops, the `anclax` schema is never created,
and `rw-bootstrap-service-accounts` crashloops on its final step
(`relation "anclax.users" does not exist`) despite completing every group, user and
grant successfully. ONE secret value, two red components.

Owner: Steve/Zach. Until it lands, prod RisingWave is usable as a database and unusable
through the console UI.

**CHECKED 2026-09-01 — there is nothing to copy.** QA's `console_license_key` holds the
IDENTICAL 52-char placeholder JSON as prod (`{"R…`, one part; a real licence is a compact
JWT — three parts, `eyJ`). So no environment has ever had a real console licence. The ask
to Steve/Zach is ONE licence for the whole on-prem estate, not a prod key. Open: whether
QA's console pod is actually running (op-qa unreachable at the time — VPN/SSO).

**Also still open:** prod's Entra redirect URI
`https://risingwave-dashboard.op-prod.usxpress.io/dex/callback` on app registration
`e112d6ce-cc60-4884-9898-8fcc5b78b0b1`, and a first COMPLETED Velero backup (~6h).

## 2026-09-08 — Tim's access, and the PR queue cleared

**Tim (Timothy Preble) had never been provisioned on op-dev.** Not expired, not blocked
by the network team, not an IP allow-list — no certificate and no bindings had ever
existed under his name. Confirmed on the cluster before anything was granted.

Proven, from a VPN'd client: op-dev is healthy end to end — `10.10.82.50:6443` open,
`rw2-sql:4567` open, `rw2-dashboard` and `risingwave-dashboard` both HTTP 200. So the
original report was client-side.

Done:
- RoleBindings to ClusterRole `admin` in `risingwave-2` and `risingwave`, applied live and
  **boundary-tested** (6 allowed / 6 denied, including nodes, kube-system secrets,
  cluster-wide secrets, flux-system). Scope matches the Phase 1 record: namespace
  super-user, not cluster-wide.
- `variant-inc/iaac-talos-flux-platform#150` → `op-dev`, **merged 2026-09-09 and
  confirmed reconciled**: both RoleBindings carry
  `kustomize.toolkit.fluxcd.io/name: rbac`, so Git owns them and a rebuild-to-validate
  keeps Tim's access. Checked at the object, not at the merge.
- Cert carries `O=risingwave-users`, a group with no bindings anywhere. Deliberate: the
  runbook's default `O=onprem-platform-users` picks up cluster-wide read, and
  `infrastructure/rbac/` on op-dev really does carry those tiers.
- `scripts/wizard-onboard-tim-op-dev.sh` (8 stages, `--rbac-only` for the 5 that need
  nobody), `scripts/triage-user-cluster-access.sh`, `scripts/pr-tim-rbac-op-dev.sh`.

**Still open:** Tim is on vacation. His certificate is stages 3, 4 and 7 of the wizard —
about ten minutes on his return.

⚠️ **Unanswered, and it should have been asked first:** nobody has confirmed which door
Tim was knocking on. The Phase 1 record has his path as psql plus the dashboard with
kubectl *explicitly excluded*. If he meant the SQL endpoint he needs a RisingWave DB user,
not this. The grant is correct and needed either way, so nothing is wasted — but it was
built on a decision record rather than on an answer.

**PR queue.** #17 closed as superseded (`310aa151` is an ancestor of `4873de43`, checked
with `merge-base --is-ancestor`, not by PR date). #20 approved and merged: QA had been on
the **19 August** image for three weeks and now carries INFRA-1675 — guardrail regex,
`apply.sh` routing, per-env account IDs, and the per-environment `risingwave` namespace
map that was our change request on #19. #18 and #21 are back with Idris; messages in
`MSG-IDRIS-PRS-2026-09-08.md`.
❌ **VERIFIED, AND IT DID NOT LAND.** `app-risingwave` on op-qa is still on `d616…`.
The apply Job `etl-pipeline-apply-djbp9` has been in `CreateContainerConfigError` for
**6d20h — 45,497 attempts**, since ~2026-09-01:

    Error: couldn't find key POSTGRES_ENTITY_USER in Secret app-risingwave/etl-pipeline-credentials

The Job is an Argo **sync hook**, so a hook that never completes blocks the sync and #20's
digest is never applied. Merging the promotion changed nothing. Same shape as
`rw-bootstrap-service-accounts` wedging `risingwave-onprem` on prod last week.

**Root cause — Blocker 1 from `REVIEW-IDRIS-ARCHITECTURE-2026-09-02.md`, which we recorded
as "deferred". It is not deferred; it has been blocking QA for a week.** The
ExternalSecret requests five keys and the Secret holds three:

| requested | present | remoteRef |
|---|---|---|
| `RW_PASSWORD` | ✅ | `op-usxpress-qa/risingwave/root/password` |
| `PG_PASSWORD` | ✅ | `op-usxpress-qa/risingwave/postgres/password` |
| `PG_USER` | ✅ | `op-usxpress-qa/risingwave/postgres/username` |
| `POSTGRES_ENTITY_USER` | ❌ | `op-usxpress-qa/risingwave/entity-postgres/username` |
| `POSTGRES_ENTITY_PASSWORD` | ❌ | `op-usxpress-qa/risingwave/entity-postgres/password` |

The `entity-postgres` records were never created in Secrets Manager. They are Terraform's,
applied through Octopus.

⚠️ **Correction to a claim made in this session.** I called this another instance of
"a green sync is not a valid value". **It is not.** The ExternalSecret reports
`SecretSyncedError` — ESO was honest. What actually happened is worse in a different way:
**ESO wrote a PARTIAL Secret**, three of five keys, so the Secret looks populated while
being unusable. The pod then gets far enough to attempt container creation and dies on the
missing key. Nothing was watching the ExternalSecret's condition, and nothing alerted for
seven days on a cluster where alert delivery was fixed on 2026-08-24.

**Fix, in this order — the order matters:**
1. Create `op-usxpress-qa/risingwave/entity-postgres/{username,password}` in Secrets
   Manager, via Terraform through Octopus. Never a local apply.
2. Confirm the Secret carries **five** keys, by listing keys — not by reading the
   ExternalSecret's condition.
3. **Then** delete the wedged Job so Argo recreates the hook at the new digest. Doing this
   before step 1 just wedges it again.
4. Verify the new pod's imageID is `sha256:5108f320…` and the Job reports Complete.

**Open question for Idris:** does the Terraform create the Postgres ROLE as well as the
Secrets Manager record? A credential that exists in SM but not in the database moves the
failure from container-create to connect-time, which is harder to see.

**Traps hit today, all self-inflicted, all caught by running against a known-good machine
rather than by review:** interface name read as reachability (invalid in WSL2), one missing
DNS record read as resolver health, the default kubeconfig path read as whether a
credential exists, "merge oldest first" applied to *parallel* promotions, and a
kustomization entry appended at the wrong indentation — invalid YAML that would have taken
`infrastructure/rbac` down. `kubectl kustomize` did refuse to build it, and the script
printed "check it by hand" instead of failing.

**Absent by design, not broken:** `rw2-pg.op-dev.usxpress.io` has no DNS record because
`rw2-pg-passthrough.yaml` was never applied (INFRA-1495). And INFRA-1496 — the source-CIDR
allow-list via CiliumNetworkPolicy — is still `filed`, which is the answer to Idris asking
where Tim posted his IP: there is nothing for an IP to be added to.

**New ticket candidate:** `op-dev.usxpress.io` resolves from the public internet. Internal
`10.10.82.x` addresses were readable from a GitHub codespace with no VPN.

### 2026-09-08 later — Idris cleared the queue; #22 reviewed twice

**#18 closed** by Idris. **#21 merged** (squash) — `apply.sh` hardening plus two new docs.
Both Round 1 asks on it turned out to be **already satisfied**, verified in the code, not
conceded: the `%TOKEN%` substitution writes to a temp file and `sha256sum` reads *that*, and
an `EXCLUDE_RE` that empties the selection exits 1 with a named error. His `EXCLUDE_RE` was
also exact — run against the tree at `4873de43`, 24 `.sql`/`.rw` files discovered, 22
excluded, exactly `Brand/100-sources.rw` and `Brand/200-ingest.rw` selected.

**#23** opened automatically from the #21 merge, promoting `ae5176cb`. It cannot deploy
either — same wedge.

**#22 (QA cutover) — two rounds, and I was wrong once.**

❌ **My Round 1 blocker "this PR is seven files" was wrong.** I read the diff GitHub
*displays*, which is computed from a merge-base predating the #21 squash. The effective
diff — `git diff --stat origin/master pr-22` — is four files and 84 lines, overlay only,
exactly as Idris described. His `apply.sh` and docs are byte-identical to master. Withdrawn
in Round 2. Same class as everything else today: the displayed artifact is a proxy; the
effective diff is the property.

✅ **And the file I had not read carried a real one.**
`deploy/overlays/qa/kustomization.yaml` reverts the QA digest from `5108f32…` (merged by
#20 today) back to `d616242…` (**19 August**). The branch predates #20 and touches the
file, so merging it undoes the promotion — invisible in the file list, invisible in the
description, green all the way. Same shape as the #17-after-#20 ordering trap, through a
different door. Fix is a rebase; better still, overlay PRs should stop pinning the digest
at all and leave it to the promotion PRs.

**Check added, because one would have caught it.** `scripts/rw-pr-triage.sh` now flags any
open PR that moves an image digest and is not titled `promote:`, prints the before/after
lines and gives the command to diff the branch against master. Verified against the real
#22 hunk (flagged) and the `PIPELINE_DIR`-only hunk from the same PR (quiet).

**#22's remaining list:** the QA wedge (blocks everything), the digest revert (one rebase),
`PIPELINE_DIR` exiting 0 on an empty match, and the unanswered Kafka-credentials question.

**Critical path is one item:** create `op-usxpress-qa/risingwave/entity-postgres/{username,
password}` through the Octopus Terraform run. Until then nothing reaches QA — not #22, not
#23, and #20's image is still not running.

### 2026-09-09 — `variant-inc/iaac-talos` #62, blocked — ✅ **APPROVED 2026-09-10 at `3441ae9`**

`fix(INFRA-1672): widen GHA OIDC trust policy for risingwave-pipeline`, +16/-18 in
`deploy/terraform/modules/irsa/gha-risingwave-pipeline-secrets-role.tf`. Review requested
from us a week ago.

The diagnosis is correct — a `workflow_dispatch` job referencing a GitHub Environment sends
`environment:<name>` as the `sub` claim, which a policy pinned to `ref:refs/heads/master`
rejects. **The size of the fix is the problem, and two changes compound:**

1. Subject becomes `repo:variant-inc/risingwave-pipeline:*`, which also matches
   `repo:…:pull_request`. Anyone able to open a PR in that repo can assume the role.
2. The same commit adds `${cluster_name}/risingwave/*` — **Tim's production path** — to what
   that role may read.

Net: a wildcard-trusted role that reads production RisingWave credentials. `StringLike`
takes a list, so naming `master` plus the three `environment:` subjects fixes the real
problem without admitting PRs.

**The PR deletes the two comments that argue against exactly this**, and both were quoted
back rather than re-argued. Verified rather than assumed:
`gha-risingwave-poc-secrets-role.tf` **is still present**, so the separation is a live
property being removed, not a historical note — two roles would read `/risingwave/*` after
this merge.

Advisories: `risingwave-2` scope granted in every environment though it is dev-only, and
`data.aws_caller_identity.current` lets a wrong-account apply succeed quietly a week after
0.5.6 died reading QA's bucket in prod.

Wiz reported 8 Medium / 5 Low / 1 Info on this PR — **all on resources it does not touch**
(`aws_s3_bucket.risingwave_state`, `grafana_admin`, `grafana_azure_ad`); Wiz scans the
module, not the diff. Two are worth their own ticket though: **no versioning and no
HTTP-deny on the RisingWave Hummock state store**, which combined with prod RisingWave
having no completed Velero backup means no recovery path at either layer.

### 2026-09-09 — INFRA-1690 filed and withdrawn the same hour. My error.

I reported a plaintext Postgres CDC password in `pipelines/employee/100-Sources.rw` and
filed INFRA-1690 against it. **There is no plaintext credential.** Line 52 is
`password = '%POSTGRES_ENTITY_PASSWORD%'` — a correctly-uppercased placeholder token, the
exact form `apply.sh` renders.

**The defect was in my check.** I redacted with two `sed` expressions in sequence:

    s/'%[A-Z0-9_]+%'/'<PLACEHOLDER-TOKEN-OK>'/g;  s/'[^']*'/'<LITERAL-VALUE-INVESTIGATE>'/g

The first correctly labelled the placeholder safe. The second then matched **its own
output** and overwrote it with the unsafe label. Reproduced against the real line: chained,
it prints `LITERAL-VALUE-INVESTIGATE`; the first expression alone prints
`PLACEHOLDER-TOKEN-OK`. **Every placeholder in the repository would have been reported as a
literal.** The check had exactly one reachable verdict — the same shape as the
`rw-prod-status.sh` gate 5 that could not pass, on 2026-09-03.

**What the proper sweep found.** `scripts/scan-pipeline-plaintext.sh`, written afterwards,
evaluates each line once through an ordered `case` rather than chained substitutions.
Across all 24 `.rw`/`.sql` files on `master`: **7 SECRET references, 3 placeholders, 0
literal usernames, 0 literal secrets.** INFRA-1637's conversion is complete on master —
better than anyone had evidence for, including Idris.

**What this cost:** a security ticket raised against a colleague's work on a false premise,
withdrawn within the hour with the cause stated. What it did not cost: any change to his
code, because the finding was checked before anyone was asked to act on it.

**Still open and unaffected:** the old Confluent key was replaced, never revoked. That needs
a Confluent Cloud administrator other than Tim.

### 2026-09-10 — #62 approved

`3441ae9` fixed both blockers, verified in the diff rather than from the commit title —
which mattered, because the title described exactly what had been asked for and that is
when a title is most tempting to trust.

- **Subject** is now an explicit allowlist: `master` plus `environment:dev|qa|prod`. No
  wildcard, so `repo:…:pull_request` no longer matches.
- **`/risingwave/*` removed.** Only `${cluster_name}/risingwave-2/*` remains, so Tim's
  production path stays with Tim's role and the two are independently rotatable again.

He went past the ask: rather than restoring the deleted scope comment he rewrote it for the
new shape and added `This role MUST NOT include /risingwave/*.` — turning an argument that
had to be quoted back at him into a standing instruction for the next person.

**Stated in the approval rather than glossed:** the policy has a second `Statement` block
that neither diff shows and which has therefore never been read. Approved on the change,
not as a certification of the whole role. Blocking a strict narrowing over unchanged
adjacent code would have been scope creep.

Advisories carried forward, neither blocking: `risingwave-2` scope granted in every
environment though it is dev-only, and `data.aws_caller_identity.current` letting a
wrong-account apply succeed quietly.

The approval also carries the three Octopus traps for the deploy — a green deploy is not an
apply (`TfApply` false outside production; the proof is the `terraform_outputs.yml`
artifact), a release freezes its variables at creation, and check the account the plan
resolves to — plus a warning that his QA test step will fail on the unrelated
`entity-postgres` wedge.

### 2026-09-10 — #62 merged; and the entity-postgres blocker may be much smaller

**#62 merged by Doke.** Deploy is Idris's, via a **new** release (an existing one is frozen
at its creation commit + variable snapshot). Only `development` offered in the dropdown —
normal lifecycle phase gating, QA unlocks after dev runs.

⚠️ **Correction — `TfApply` is `true` on qa.** Idris read it off the project. The note in
`octopus-green-but-no-apply` said "false everywhere but production"; that is now wrong.
It was set during the July AWS SSO work and never scoped back, so **every QA deploy applies
for real** while dev stays plan-only. Whether QA *should* be apply-enabled is still an
unmade decision — it is true by inheritance, not by intent.

⚠️ **Correction — "entity-postgres is a different host with different credentials" was
mine, not Idris's.** I took it from `WRITEUP-FOR-IDRIS-2026-08-31.md`, a design document I
wrote. Idris, who runs it, says the `.sql` files go **to the Postgres deployed for
RisingWave — 5432, the same instance backing RisingWave meta**.

Both can be true if it is one instance holding two databases, which is what the merged
routing already assumes: it compares `HOST:DB`, so same host is allowed and same host **and**
database is refused with exit 1.

**Three questions to Idris settle the size of the blocker** (asked 2026-09-10):

| answer | consequence |
|---|---|
| `POSTGRES_ENTITY_USER` == `PG_USER` | **no Terraform, no Octopus** — point the ExternalSecret at the existing `postgres/{username,password}` records and QA unwedges the same day |
| separate role on the same instance | a role Idris creates on a Postgres we already run; still needs the SM records, but no unknown upstream system and no dependency on Tim |
| `POSTGRES_ENTITY_DB` == the meta database | the #20 guard refuses the file (exit 1) and must change before anything applies |

**Proven:** #62 merged; QA `TfApply=true`.
**Killed:** "entity-postgres is an external system nobody has identified" — unverified, and
its source was our own design doc rather than the running system.
**Trap:** a claim that originates in a document you wrote reads back exactly like a finding.
The person operating the thing is the primary source; check which one you are quoting.

### 2026-09-10 — the entity-postgres wedge, settled on the cluster

`scripts/probe-entity-postgres.sh qa` (read-only, no value printed). **The blocker is not a
missing secret. It is a mandatory requirement for a database that does not exist.**

`app-risingwave/etl-pipeline-endpoints` on op-qa:

| key | value |
|---|---|
| `PG_HOST` | `pg-postgresql.risingwave.svc.cluster.local` |
| `PG_DB` | `risingwave` |
| `POSTGRES_SERVER` | **empty** |
| `POSTGRES_ENTITY_DB` | **empty** |

`PG_HOST`/`PG_DB` are the meta store's own endpoint and database — identical to the meta
pod's `RW_SQL_ENDPOINT` / `RW_SQL_DATABASE`. The application-database fields are present and
blank. QA has exactly three services on 5432: istio's passthrough gateway,
`ghostunnel-rw-postgres`, and `pg-postgresql`. There is no second Postgres.

And on the Job (`etl-pipeline-apply`, active=1):

    env POSTGRES_ENTITY_USER      <- secret etl-pipeline-credentials/POSTGRES_ENTITY_USER   optional=False
    env POSTGRES_ENTITY_PASSWORD  <- secret etl-pipeline-credentials/POSTGRES_ENTITY_PASSWORD optional=False

**Both corrections in one place.**
❌ Mine — "entity-postgres is a separate host with its own credentials." It is not; it came
from `WRITEUP-FOR-IDRIS-2026-08-31.md`, our own design document.
❌ Idris's — "the `.sql` goes to the Postgres created for RisingWave." Directionally right
about the instance, but `POSTGRES_SERVER` is blank, so no `.sql` file can run at all today.
✅ His account of the credentials is exact: two records, `root` (RisingWave login) and
`postgres` (the instance). Both exist and both already sync.

**The fix is not the Terraform change we had on the critical path.** Creating
`entity-postgres/{username,password}` produces a pod that starts and then exits 1 on the
blank `POSTGRES_SERVER` the moment a `.sql` file appears — the failure moves, it does not go.

Cheapest correct fix, in `risingwave-pipeline` overlays:
1. drop `POSTGRES_ENTITY_USER` / `_PASSWORD` from the ExternalSecret `data:` (ESO stops
   erroring and writes a complete Secret);
2. drop the two `env` entries from the apply Job, or set `optional: true`;
3. delete the wedged Job so Argo recreates the hook.

No Terraform, no Octopus run, no credential invented for a server that does not exist.
Reinstate all three the day an application database actually exists — which is Tim's design
question, not a QA blocker.

**Proven:** one Postgres instance on QA; entity fields blank; both entity env vars mandatory.
**Killed:** "create the SM records" as the critical path — it was the answer to the error
message, not to the problem.
**Trap:** a missing credential reads as "create the credential". It can equally mean the
system it authenticates to was never built. The error names the key, never the absence
behind it. Nine days of QA sat behind that reading.

### 2026-09-10 later — #22 Round 3 posted at b04a394 (NOT approvable)

Idris force-pushed three commits: the cutover, the empty-`PIPELINE_DIR` fix, and
"drop entity-postgres refs that block ESO in QA" — acting on the finding above within
the hour.

**Cleared, each verified rather than read:** rebase real (`merge-base --is-ancestor`,
`ae5176c` ancestor of `b04a394`); digest revert gone (`5108f32…` on both sides); empty
`PIPELINE_DIR` exits 1 at `apply.sh:57-58`; base `externalsecret.yaml` −8 and
`job.yaml` −6.

❌ **BLOCKER — the QA overlay no longer renders.** He removed data entries 3 and 4 from
the base; `deploy/overlays/qa/kustomization.yaml` still patches those indexes:

    $ kubectl kustomize deploy/overlays/qa      # b04a394
    error: replace operation does not apply: doc is missing path: /spec/data/3/remoteRef/key: missing value

Argo would report a sync error and apply nothing — QA stays wedged through a different
door. `deploy/overlays/prod/kustomization.yaml` carries the identical pair.

❌ **BLOCKER — Brand's Kafka tokens.** `100-sources.rw` needs `%KAFKA_TOPIC_BRAND%`,
`%KAFKA_STARTUP_MODE%`, `%KAFKA_SCHEMA_REGISTRY_MESSAGE%`; the branch's
`qa/endpoints.yaml` defines none and the ExternalSecret maps no Kafka key. Kafka
credentials are not in QA Secrets Manager either — same hole as `entity-postgres`.
`200-ingest.rw` carries no tokens.

⚠️ Correction: I reported `200-ingest.rw` as missing from the branch. It exists — my
`git show` invocation was wrong, not the file.

**Proven:** the render fails; the three Kafka tokens are unsupplied.
**Killed:** "he addressed both change requests, so it can merge" — two of the three
commits are right and the third broke the build.
**Trap:** an index-based JSON patch (`/spec/data/3/...`) is coupled to the LENGTH of a
list another file owns. Shortening the base moves every later index; the patch either
fails loudly (this time) or silently retargets a different entry — which would have
repointed `PG_USER` at `entity-postgres` and broken a credential that works today.
Patch by value, not position. `kubectl kustomize` on the overlay is the only check that
sees it; no diff review would.

### 2026-09-10 — #22 fixed by us and APPROVED at 9c63bc4

Doke asked for the fix rather than another round-trip. `scripts/pr22-fix-and-push.sh`
removed the four stale patch entries (2 qa, 2 prod), rendered both overlays, and pushed
`b04a394 -> 9c63bc4` to Idris's branch after confirmation.

**Rendered QA is correct:** 3 ExternalSecret entries, `RW_PASSWORD` from
`risingwave/root`, `PG_PASSWORD` and `PG_USER` from `risingwave/postgres`; no mandatory
`POSTGRES_ENTITY_*` env on the Job. Prod renders clean.

⚠️ **The first run of the gate failed on its own bad checks, not on the change.**
`grep entity-postgres` matched **`entity-postgresql`** inside a ConfigMap comment, and
the entry regex assumed `secretKey` precedes `remoteRef` — kustomize sorts keys
alphabetically, so `remoteRef` comes first and it counted zero entries. Replaced with
`scripts/verify-rendered-qa.py`, which parses the YAML and is tested three ways: good
render passes, a render with `PG_USER` repointed at `entity-postgres` fails, a qa render
verified as prod fails.

**Still open on #22, stated in the approval:** the three `%KAFKA_…%` tokens. If the apply
Job is a **PreSync** hook, a failing hook means the sync never completes and #20/#23's
digest still is not applied — QA would stay on the 19 August image by a different route.
Asked Idris to read `.metadata.annotations.argocd\.argoproj\.io/hook` before merging.

**Proven:** the render is correct at 9c63bc4.
**Killed:** "merging #22 unblocks QA" — not until the Kafka tokens resolve, and possibly
not even then depending on the hook phase.
**Trap:** a verifier tested only against fixtures the author wrote will encode the
author's assumptions about the format. Real `kustomize` output sorts keys; my fixture
did not. Feed a gate the real artifact before trusting its verdict either way.

### 2026-09-10 — the apply Job is a **Sync**-phase hook (read from the cluster)

    $ bash scripts/kq.sh qa -n app-risingwave get job etl-pipeline-apply \
        -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/hook}'
    Sync

So the hook runs as part of the sync and its failure fails the sync — which is why
#20's digest never landed while the Job sat in `CreateContainerConfigError`.

**What merging #22 does, stated carefully.** The Job *is* the hook and carries the image
digest, so a new sync creates it at `5108f32…` rather than the 19 August image. ESO
writes a complete three-key Secret and the container starts. Then `apply.sh` reaches
`Brand/100-sources.rw` and cannot resolve `%KAFKA_TOPIC_BRAND%`,
`%KAFKA_STARTUP_MODE%`, `%KAFKA_SCHEMA_REGISTRY_MESSAGE%`.

Merging therefore converts a nine-day invisible wedge (45,497 container-creation
attempts, RESTARTS 0, no alert) into a named failure on the first run. That is worth
having. It does **not** put Brand live on QA.

⚠️ **Not verified:** which check catches the unresolved tokens — the placeholder
refusal, or RisingWave rejecting the rendered statement. Either fails; the message
differs. Do not tell anyone "it will refuse and name them" as established.

**The Kafka gap is probably Tim-shaped too.** Brand's credentials come from Confluent
Cloud, and the Confluent Cloud administrator is Tim — the same person INFRA-1637 is
blocked on for the old key's revocation. A second Confluent admin unblocks both.

### 2026-09-10 — #22 MERGED, QA unwedged after nine days, and stopped by the right guard

Merged at `9c63bc4` (squash). Argo could not act on it: the old hook Job held
`argocd.argoproj.io/hook-finalizer`, marked for deletion at **19:31Z** and never
finishing, because **Argo will not release the finalizer until the hook completes and
the hook could not complete** — its pod carried the pre-merge spec demanding
`POSTGRES_ENTITY_USER`. The fixed manifest could not reach that pod; the new Job was
never created. **The broken thing was holding the door for its own replacement.**

Released by Doke on QA: cleared `.operation` on the `risingwave-etl` Application, then
dropped the Job's finalizer (guarded: only because it already carried a
`deletionTimestamp` and its pod had never started a container).

**Result — real progress:**

| | before | after |
|---|---|---|
| ExternalSecret | `SecretSyncedError`, 9 days | `Ready=True SecretSynced` |
| Secret | 3 of 5 keys, partial | 3 of 3, complete |
| Image | `d616242…` (19 August) | `5108f32…` |
| Pod | `CreateContainerConfigError`, 45,497 attempts | runs, produces output |

Then it refused, correctly:

    ERROR: POSTGRES_SERVER is required when .sql files are present but is not set.

❌ **My first explanation was wrong.** I said `EXCLUDE_RE`'s `^pipelines/Brand/...`
anchor could not match at runtime. It matches fine — `rel="${f#/pipeline/}"` yields
`pipelines/Brand/300-transform.sql`.

✅ **The actual cause: the running image predates the feature.** `EXCLUDE_RE` is absent
from `build/apply.sh` at `4873de43`, the commit behind `5108f32…`. Verified:

    gh api ... contents/build/apply.sh?ref=4873de43 | grep EXCLUDE_RE   ->  no match

So the image ignored the exclusion, selected all 24 files, saw a `.sql`, and refused.
The overlay is correct; **the binary is a version behind it**. The tell was in the log's
absence, not its content — not one `exclude` line was printed.

⚠️ **Correction to a claim I made on 2026-09-08.** I reported `EXCLUDE_RE` "verified
exact — 24 discovered, 22 excluded". That verification was against the repo tree with my
own `grep`. It said nothing about whether the deployed image implements `EXCLUDE_RE` at
all. Testing a regex is not testing the code that runs it.

**Next:** promote the newer build (#23 promotes `ae5176cb`, and the #22 merge should have
opened another). The Kafka tokens remain unresolved and will be the next refusal.

**Proven:** QA is off the 19 August image; the Secret is complete; the guard works.
**Killed:** the anchor theory; and "EXCLUDE_RE is verified" as a statement about QA.
**Trap:** config can be promoted ahead of the code that reads it. A key the running
image does not know about is silently ignored — this one only surfaced because an
unrelated guard tripped.

### 2026-09-11 — the delivery path is PROVEN on QA, and the canary found a third blocker

`pod/etl-pipeline-apply-xp2hp  Completed`, Job self-deleted on `HookSucceeded`,
`sync=Synced health=Healthy phase=Succeeded`. **First pipeline file ever applied to QA's
RisingWave through this path.** August's "proven" run carried a smoke payload.

**What the canary found — nobody was looking for it.** `deploy/base/job.yaml` ran with
`readOnlyRootFilesystem: true` and **no volumes at all**, while `apply.sh` renders every
file through `mktemp` before applying it:

    mktemp: Read-only file system

So **no pipeline file could be applied on QA, ever** — Brand included. The Kafka values
would have landed and it would still have failed. Invisible until now because the render
step arrived with #21 and nothing had called `mktemp` on this path before.
Fixed in #28: an `emptyDir` at `/tmp` plus `TMPDIR`, with `readOnlyRootFilesystem`,
`runAsNonRoot`, dropped capabilities and seccomp all left intact.

**Three blockers in series, each hidden behind the last:**

| # | blocker | how it was found |
|---|---|---|
| 1 | ExternalSecret demanded `entity-postgres`, a database that does not exist | reading the ConfigMap's empty `POSTGRES_SERVER` |
| 2 | the image predated `EXCLUDE_RE`, so it selected all 24 files | the **absence** of `exclude` lines in the log |
| 3 | no writable `/tmp`, so `mktemp` failed on the first file | running a file that depends on nothing |

None was findable by reading a diff. Each only became visible once the previous cleared.

⚠️ **New Argo behaviour worth knowing: a failed hook Job makes the next sync a no-op that
replays the old failure.** `started == finished` (same second), the syncResult carries the
previous Job's `backoff limit` message, and nothing re-runs — even after the fix is
merged. It clears once the failed Job is deleted (by `ttlSecondsAfterFinished` or
`BeforeHookCreation`). We chased this twice today before spotting the timestamps.

**Proven:** the full chain — commit → build → promotion PR → Argo → `apply.sh` →
RisingWave.
**Not verified:** the canary's objects by *value*. `phase=Succeeded` is a green sync, and
by our own rule that is not a value check; `canary_promotion_mv` has not been selected.
No SQL session to `risingwave-frontend:4567` is set up.
**Remaining for Brand:** three strings from Tim — `KAFKA_TOPIC_BRAND`,
`KAFKA_STARTUP_MODE`, `KAFKA_SCHEMA_REGISTRY_MESSAGE` — and confirmation that
`secret.yaml` has created the twelve `kafka_*` SECRET objects on QA (corrected 2026-09-11: twelve, not nine — nine come from AWS keys, three are literals in the file) (its last run, 9 days
ago, **failed**).
**Cleanup owed:** `PIPELINE_DIR` back to `/pipeline/pipelines`, canary file removed.

### 2026-09-11 later — Brand's three values found without Tim; two new blockers behind them

Idris said "only Tim knows the topic name". He was wrong, and so was the premise:
**every value was already in a system of record.**

| key | value | where it came from |
|---|---|---|
| `KAFKA_TOPIC_BRAND` | `qa_brand_management_cdc_brand_avro` | Confluent topic list on `lkc-19mn63`, via the api_key in `op-usxpress-qa/risingwave/kafka` — 14 topics, exactly one Brand |
| `KAFKA_STARTUP_MODE` | `earliest` | Idris's decision |
| `KAFKA_SCHEMA_REGISTRY_MESSAGE` | `USXpress.Standard.Types.Brand.V1.company_master` | the schema of subject `qa_brand_management_cdc_brand_avro-value`, namespace + record joined |

**#29 must not merge as written** — it sets `KAFKA_SCHEMA_REGISTRY_MESSAGE: unknown`, a literal
placeholder that passes `apply.sh`'s non-empty check and then fails inside RisingWave at
decode time. A blank fails loudly; `unknown` fails quietly. Commented, not approved.

❌ **New blocker — QA's schema-registry credentials are hollow.**
`op-usxpress-qa/risingwave/kafka` lists nine keys, but `kafka__schema_registry_endpoint`
is an **empty string**. Dev's `op-usxpress-dev/risingwave/kafka` has all nine populated
(endpoint 48 chars). **The QA subject lives in DEV's registry** — `qa_brand_…-value` is
listed there — so QA needs dev's endpoint value, not one of its own. Without it,
`secret.yaml` creates a `kafka_schema_registry_endpoint` SECRET containing nothing and the
Avro source cannot decode. Same shape as `POSTGRES_SERVER`: the key exists, the value is
empty, and everything downstream looks configured.

⚠️ **Casing differs between environments:** dev's keys are `KAFKA__…`, QA's are
`kafka__…`. If `secret.yaml` reads one casing it silently gets nothing from the other —
a candidate explanation for its failed run on 2026-09-02.

❌ **iaac-talos and iaac-risingwave-onprem declare the SAME resources.** The #62 QA deploy
failed with `BucketAlreadyOwnedByYou: risingwave-state-op-usxpress-qa` and
`EntityAlreadyExists: op-usxpress-qa-risingwave`. Idris found the cause:
`iaac-risingwave-onprem/deploy/terraform/main.tf` creates `aws_s3_bucket.risingwave` and
`aws_iam_role.risingwave_irsa` (`${cluster_name}-risingwave`) — and `iaac-talos`'s
`module.irsa[0]` declares both. **Do not import them into the iaac-talos state**: two
owners of RisingWave's Hummock bucket means a destroy or replace on either side deletes
the object store. Fix by removing the declaration from `iaac-talos`. The apply failing is
what protected us; QA has `TfApply=true`, so it was a real apply and it reached
`Creating...` on four resources first.

⚠️ **A standing claim of mine needs re-checking.** That module enables
`aws_s3_bucket_versioning` on the RisingWave bucket. I have been carrying "the Hummock S3
state store has no versioning" as an open risk — that may be wrong for buckets this
project created. Verify per cluster before repeating it.

**Proven:** all three Brand values, from Confluent and the schema registry rather than
from anyone's memory.
**Killed:** "only Tim knows the topic name", and "the Kafka gap needs a Confluent admin".
**Trap:** a placeholder that satisfies a validator. `unknown` is worse than empty
precisely because the guard lets it through.

### 2026-09-11 — two checks, one correction

✅ **CORRECTION: the Hummock buckets DO have versioning.** Verified directly, all three:

    dev    Enabled
    qa     Enabled
    prod   Enabled       (risingwave-state-op-usxpress-<env>, get-bucket-versioning)

I have repeated "no versioning on the Hummock S3 state store" as an unowned risk for
weeks. **It is wrong** — `iaac-risingwave-onprem` sets `aws_s3_bucket_versioning` on the
bucket it creates, and every environment shows Enabled. The claim was never checked after
that Terraform landed. The Velero gap on prod RisingWave is a separate question and is
NOT covered by this check.

❌ **QA has no schema-registry access at all** — not one empty field, three:

    kafka__schema_registry_endpoint   = EMPTY
    kafka__schema_registry_api_key    = EMPTY
    kafka__schema_registry_api_secret = EMPTY

while `kafka__api_key`, `_secret`, `bootstrap_server`, `rest_endpoint`, `resource_id` and
`service_account` are all populated. Dev's equivalents are all populated (endpoint 48
chars). So QA can reach Kafka and cannot reach the registry — and `Brand/100-sources.rw`
is `FORMAT PLAIN ENCODE AVRO`, which needs the registry to decode anything.

**This is a decision, not a lookup.** Either copy dev's registry credentials into QA's
secret (fast, but shares one credential across two environments — the opposite of what
INFRA-1637 has been about), or mint a QA-specific schema-registry API key in Confluent
Cloud, which needs an administrator. Doke's call.

### 2026-09-11 — QA registry access FIXED, and it never needed Confluent at all

**The house pattern, found by looking for the repo rather than for a person:**
`variant-inc/iaac-confluent-cloud` manages Confluent (environments, clusters, service
accounts, `confluent_api_key.schema_registry`, `confluent_role_binding.schema_registry_rw`
— ResourceOwner on `subject=*`). The credentials land in **one secret per AWS account**:
`dx--ccloud-schema-registry-master`, carrying exactly the three fields we needed. No
per-app secret in the estate carries registry fields — checked `dx__analyticsconsumer-`
and `dx__orders-kafka-creds`, both seven keys, no registry.

**Proof before acting:** dev's `op-usxpress-dev/risingwave/kafka` holds values
byte-identical to dev's master (compared by sha256, no value printed). So copying is the
convention, not a shortcut.

**Done:** `scripts/copy-registry-creds-to-rw.sh qa` wrote the three values into
`op-usxpress-qa/risingwave/kafka`, preserving the six populated fields and the target's
lowercase `kafka__` casing (the master is uppercase `KAFKA__`).

**Verified, not assumed:**

    GET /subjects -> HTTP 200
    subjects visible: 23
      'qa_brand_management_cdc_brand_avro-value' is visible
    GET the Brand schema -> HTTP 200
      record: USXpress.Standard.Types.Brand.V1.company_master

That record name independently confirms the value given to Idris for #29.

❌ **Killed, and it was mine:** "QA needs a schema-registry key from a Confluent admin."
I had written a request document and a wizard to mint a key. Both would have worked and
left a **second** credential for the same service account — more sprawl, in the middle of
INFRA-1637 reducing exactly that. The correct answer was a copy that every other consumer
already does.

**Trap:** when access is missing, the reflex is to ask who can grant it. The better first
question is how the organisation already grants it — `gh repo list` found
`iaac-confluent-cloud` in one command. Doke asked for the repo; I was drafting an email.

**Remaining for Brand:** #29 updated with the real record name (Idris), then
`secret.yaml` against QA, then merge and sync.
**Prod note:** `op-usxpress-prod/risingwave/kafka` still does not exist — that record is
Terraform's, in `iaac-risingwave-onprem`. Prod's account has its own
`dx--ccloud-schema-registry-master` to copy from once the record exists.

### 2026-09-11 (evening) — first SQL session into QA RisingWave. Four answers, one new blocker.

`bash scripts/rw-verify-canary.sh qa`, run by Doke on WSL. Port-forward to
`svc/risingwave-frontend`, root password read from `app-risingwave/etl-pipeline-credentials`.
All five queries returned; no value was printed.

**Proven:**

1. **`SHOW DATABASES` -> one row: `dev`.** On the **QA** cluster. So `RW_DB` must stay `dev`
   in every environment — the name is a database inside RisingWave, not an environment label.
   This is the evidence behind the objection to #29's `RW_DB: qa`, which would have failed at
   connect time. Previously this was an inference from a log line; it is now a query.
2. **The canary landed, by value.**

       name                 | relation_type
       canary_promotion     | table
       canary_promotion_mv  | materialized view

       row_count | last_applied
       1         | 2026-09-11 13:02:10.526+00:00

   The delivery path (commit -> GHA -> ECR -> promotion PR -> Argo sync -> Job -> RisingWave)
   is proven end to end with data in a materialized view, not with `phase=Succeeded`.
   See [[eso-secretsynced-not-content-check]] — this is the check that rule asks for.

**New blocker, found by the same run:**

3. **`rw_catalog.rw_sources` -> 0 rows.** No Kafka source exists on QA at all.
4. **`rw_catalog.rw_secrets` -> 0 rows.** The twelve `kafka_*` SECRET objects **do not exist**.
   `secret.yaml` has never run successfully against QA.

⚠️ **The ordering trap this exposes:** Brand's source DDL references `SECRET kafka_*`. With
`PIPELINE_DIR` restored, `EXCLUDE_RE` selects exactly **two Brand files** and excludes 22 —
and `secret.yaml` is one of the excluded 22 unless it sits inside the Brand directory. If it
does not, the Brand source will fail at apply with a missing-secret error that reads like a
credentials problem and is actually a **file-selection** problem. Check which side of
`EXCLUDE_RE` `secret.yaml` falls on **before** merging #29, not after the apply fails.

**Traps:** `rw-sql.sh` reports two contexts serving 10.10.82.51 and uses the first
(`op-usxpress-qa-sso`); both are QA, so the note is informational. `rw_secrets` returns names
only — RisingWave will not surrender the values, which is why listing is the only available
confirmation that `secret.yaml` ran.

### 2026-09-11 (late) — the secrets mechanism already exists. Nobody has pressed it.

Read from GHE, not inferred: `.github/workflows/secret.yaml` in `variant-inc/risingwave-pipeline`.

**What it is:** a `workflow_dispatch` workflow with `environment` as a **choice input —
dev / qa / prod** — and `connector` as kafka / mongodb / both. It assumes
`arn:aws:iam::<acct>:role/gha-op-usxpress-<env>-risingwave-pipeline-secrets` by OIDC, reads
`op-usxpress-<env>/risingwave/kafka`, `sed`-substitutes the `%TOKEN%` placeholders in
`pipelines/shared/000-secrets.rw`, and runs it through `psql`.

⚠️ **Three framings of this problem in one hour; only this one is from the file.**
"Nothing in the delivery path creates the secrets" (wrong), then "it's a `PIPELINE_DIR`
selection-scope fix" (wrong). It is a separate manual workflow, by design, and the QA path
is a dropdown option that has never been selected. The lesson is the standing one — read the
artifact before theorising about the mechanism. See [[proxy-is-not-the-property]].

**Counts, corrected:** `000-secrets.rw` creates **12** `kafka_*` secrets, not nine. Nine
values come from the AWS record; three are literals in the file —
`kafka_security_protocol = 'SASL_SSL'`, `kafka_sasl_mechanism = 'PLAIN'`, and
`kafka_group_id_prefix`, which the workflow **derives from the environment name** and does not
read from AWS (`qa` -> `qa_kafka_prefix`; prod is the odd one, `prodkafka_prefix`, no
underscore). Plus 3 mongodb secrets = 15 with `connector: both`.

**Today's registry fix was this workflow's prerequisite.** It reads
`.kafka__schema_registry_api_key`, `…api_secret` and `…endpoint` from the QA record. Those
were **empty strings** until we populated them this afternoon. Had anyone dispatched this
against QA last week, `sed` would have substituted empty values, `CREATE SECRET` would have
succeeded with `AS ''`, the verify step would have listed 12 names, and the workflow would
have gone green — a perfect instance of [[eso-secretsynced-not-content-check]] one layer up.

**Independent confirmation of `RW_DB`:** every `psql` invocation in this workflow is `-d dev`,
on all three environments. That is a second source for
[[rw-database-is-named-dev-everywhere]].

**Traps before dispatching it against QA:**
- Use `connector: kafka`, **not** the `both` default. The mongodb *fetch* is guarded by
  `describe-secret`, but the mongodb *substitution* is guarded only by `$CONNECTOR` — so with
  no `op-usxpress-qa/risingwave/mongodb` record, `both` creates three secrets holding `''`.
- ~~`CREATE SECRET` has no `IF NOT EXISTS`, so this is one-shot.~~ **Wrong — corrected
  2026-09-11 by running it.** `000-secrets.rw` pairs every `CREATE` with a
  `DROP SECRET IF EXISTS`, so it is idempotent and safe to re-run after a credential
  rotation. The one real constraint: once a source references a secret, RisingWave refuses
  to drop it, so re-running after Brand exists will fail on those names.
- `RISINGWAVE_HOST` / `RISINGWAVE_PORT` are **GitHub environment secrets**, so a `qa`
  environment must exist in repo settings and carry them.
- `runs-on: risingwave-pipeline` is a self-hosted ARC runner. It must have a route to QA's
  frontend, most likely `rw-sql.op-qa.usxpress.io:4567` via the tcp-passthrough Gateway
  (verified serving on QA 2026-08-20, INFRA-1645).

**Open, checkable:** does `gha-op-usxpress-qa-risingwave-pipeline-secrets` exist in account
`527101283767`, and does a `qa` GitHub environment exist with both host secrets.

### 2026-09-11 (night) — QA's secret sync: the workflow assumes the wrong role. Three one-liners.

Chased to ground from the live accounts, not from the repo's intent.

**There are two GHA OIDC roles per cluster, deliberately separated:**

| role | Secrets Manager path | trust subject |
|---|---|---|
| `gha-op-usxpress-<env>-risingwave-poc-secrets` | `…/risingwave/*` (Tim's) | `…:environment:dev\|qa\|prod` ✅ |
| `gha-op-usxpress-<env>-risingwave-pipeline-secrets` | `…/risingwave-2/*` | `…:ref:refs/heads/master` + the three environments (after iaac-talos #62) |

`secret.yaml` reads `op-usxpress-<env>/risingwave/root` and `…/risingwave/kafka` — **Tim's
path**. So the poc role is the correct one, and its trust already accepts `environment:qa`.

**The regression:** before 2026-09-01 the workflow assumed
`gha-op-usxpress-${ENV}-risingwave-poc-secrets` (with the account hardcoded to dev's
`700736442855`, which is why it only ever worked on dev). The INFRA-1675 commit of
2026-09-01 correctly parameterised the account **and** changed the role name to
`-pipeline-secrets`. That one word is why the 2026-09-01 run died at `Configure AWS via OIDC`
with every later step skipped.

**Both roles carry the same copy-paste defect in their resource ARN** — QA's poc role grants
`arn:aws:secretsmanager:us-east-2:700736442855:secret:op-usxpress-dev/risingwave/*`: dev's
account, in QA's role. iaac-talos #62 fixed exactly this pattern on the *pipeline* role's file
and never touched the poc role's. See [[manifests-copied-across-branches]].

**The fix — three one-liners:**
1. `risingwave-pipeline` `.github/workflows/secret.yaml`: role name back to
   `-risingwave-poc-secrets`, keeping the Sept 1 per-env account block. A revert of one string.
2. `iaac-talos` `deploy/terraform/modules/irsa/gha-risingwave-poc-secrets-role.tf`: ARN to
   `${data.aws_caller_identity.current.account_id}` + `${var.cluster_name}`, mirroring #62.
3. GitHub repo settings: the `qa` environment has **zero** secrets; add `RISINGWAVE_HOST`
   and `RISINGWAVE_PORT` (dev has 4 — those two plus `POSTGRES_HOST`/`POSTGRES_PORT`).

**Proven, by enumeration:** QA holds seven `op-usxpress-qa/risingwave/*` secrets and **zero**
`risingwave-2` — so the pipeline role's path does not exist in QA at all, and widening its
trust could never have been enough. Confirms [[risingwave-onprem]]'s dev-only rule from the
account side.

⚠️ **Correction to this afternoon:** I hung a QA-destroy warning on iaac-talos #62. Its diff
touches only the GHA role file. The duplicate bucket/role came from **#60**
(`feat(irsa): add RisingWave on-prem IRSA role and S3 state bucket`, merged), and **no open PR
removes it** — the four `terraform state rm` addresses are a plan, not a change. The risk in
[[two-projects-one-resource]] is live and unmitigated, but nothing imminent will trigger it.

**Deploy:** #62 is merged and **not deployed**. iaac-talos reaches AWS only through an Octopus
release from master — dev first (`TfApply` false, so it prints the plan and changes nothing),
then QA (`TfApply` **true**, applies for real).

**Still blocked beyond QA:** prod has no `prod` GitHub environment at all (only
`user-access-prod`), and no `op-usxpress-prod/risingwave/*` records yet.

### 2026-09-11 (night) — QA has its twelve Kafka secrets. Done locally, not by the workflow.

`bash scripts/rw-create-kafka-secrets.sh qa` — every gate passed (9 keys read from
`op-usxpress-qa/risingwave/kafka`, 12 rendered, no empty value, no surviving placeholder, QA
held none already), then `DROP … / CREATE_SECRET` twelve times, then the verifier listed
**12 rows** from `rw_catalog.rw_secrets`. Listed, not inferred from an exit code.

This is the same DDL from the same file with the same values the GHA workflow would have used
— it bypasses only the broken OIDC role, not the mechanism. The workflow remains the durable
path and still needs its three one-liners ([[two-gha-roles-one-pipeline-repo]]).

**Proven by doing it:** `000-secrets.rw` is idempotent (`DROP SECRET IF EXISTS` before each
`CREATE`). Correction recorded above.

**Open, and unresolved all day:** Brand's directory holds four applicable files
(`100-sources.rw`, `200-ingest.rw`, `300-transform.sql`, `400-sink.rw`) but this morning's
apply reported selecting **two**. Resolve before calling Brand delivered — a pipeline that
applies its source and not its sink looks identical to a working one from the sync status.

**Next:** merge #29 (approved), let Argo sync the ConfigMap and re-run the hook Job, then
confirm by value: `SELECT name FROM rw_catalog.rw_sources;` should show `kafka_brand`.

### 2026-09-11 (night) — Brand is BUILT on QA. Two reasons it holds no rows, only one is a defect.

#29 merged -> Argo synced in seconds -> the hook Job applied Brand. Confirmed by value:

    rw_sources    : kafka_brand
    rw_relations  : kafka_brand (source), mv_brand (mv), mv_brand_state (mv)
    mv_brand      : 0 rows

**The 4-vs-2 file question is answered, and it is deliberate.** The Job log shows
`exclude pipelines/Brand/300-transform.sql` and `exclude pipelines/Brand/400-sink.rw` — they
are in `EXCLUDE_RE`, not missed by selection. Correct: the `.sql` routes to the app database
and the sink targets it, and `POSTGRES_SERVER` is empty because entity-postgres does not exist
([[missing-credential-may-mean-missing-system]]). Brand's Kafka half applies; its
app-database half is held back on purpose. **Not a bug — stop re-raising it.**

**Defect: `GroupAuthorizationFailed (Broker: Group authorization failed)`**, in
`risingwave-compute-default-0`, every ~2s, `source_name="kafka_brand" source_id=25`.

What this is NOT: a bad credential. The same run **fetched watermarks successfully** and the
batch scan `SELECT * FROM kafka_brand LIMIT 1` returned cleanly — batch scans use no consumer
group. So SASL cluster auth and topic read both work. The service account lacks a Confluent
role binding on the **consumer group** prefix, which the source sets from
`secret kafka_group_id_prefix` = `qa_kafka_prefix`. Needs `DeveloperRead` on
`group=qa_kafka_prefix*` (PREFIXED). Look in `iaac-confluent-cloud` before asking an admin —
that is what worked for the registry this afternoon ([[ccloud-registry-master-per-account]]).

**Not a defect: the topic is empty.** `low: 194, high: 194`, `NoDataToBackfill`. Low == high
means zero retained messages; 194 were produced historically and aged out. With
`scan.startup.mode = earliest` the source starts at 194, which is already the end. **Even
with the binding fixed, `mv_brand` stays 0 until someone produces to
`qa_brand_management_cdc_brand_avro`.** Anyone expecting rows in a demo needs to know this
now, not during it.

⚠️ **Still unproven: Avro decode.** The registry credentials were verified out-of-band by REST
this afternoon (HTTP 200, correct record name), but no message has been decoded through them,
because there are no messages. Do not report the Avro path as working until a row lands.

**Traps this session paid for:** a count of 0 from a materialized view is the same shape as a
working pipeline with an empty topic, a pipeline with no group authorization, and a pipeline
with a broken schema registry. The count alone cannot tell them apart — the compute log can.
Add [[adjacent-step-green-signals]] instance: `SELECT * FROM source LIMIT 1` succeeding proves
the *batch* path, not the *streaming* path, and they use different authorization.

### 2026-09-11 (late) — the group-authz fix, found in the topics repo. Two conventions that never met.

`GroupAuthorizationFailed` has a precise cause, confirmed from source in
`variant-inc/ix-kafka-topics-users` (the repo that owns Confluent topics, users and ACLs —
**not** `iaac-confluent-cloud`, which only builds clusters and service accounts; my earlier
steer there was wrong).

**Cause 1 — `users/risingwave.yml` has no `consumer_groups:` block at all.** It grants only
topic READ. Every other consuming user has one (`analyticsconsumer`, `geoservices`, `graph`,
`trailers`, `fivetran`, `driverexperiencetechnology`). RisingWave was never granted a group.

**Cause 2 — and this is why adding one naively still fails.** `deploy/terraform/users.tf:44`
renders every group ACL as:

    group = "dx__${local.prefix}${group.prefix}"

with `main.tf:4` -> `prefix = var.confluent_prefix != "" ? "${var.confluent_prefix}_" : ""`
(QA `qa_`, **prod empty** — which is why prod's topics are unprefixed). So the ACL always
grants **`dx__<env>_<name>`**.

RisingWave's consumer group comes from `secret kafka_group_id_prefix`, which
`risingwave-pipeline`'s `.github/workflows/secret.yaml` **derives** as `${ENV}_kafka_prefix`
(prod: `prodkafka_prefix`). There is no `dx__`. The two never intersect, in any environment.

**The fix is two changes, and neither side is wrong alone:**
1. `users/risingwave.yml`: add `consumer_groups` with `prefix: risingwave` (+ `used_by`, as
   the neighbours do) -> grants `dx__qa_risingwave*` / `dx__risingwave*`.
2. `secret.yaml`: derive `kafka_group_id_prefix` as `dx__` + (`""` for prod else `${ENV}_`) +
   `risingwave` — mirroring `local.prefix` exactly. Then re-run
   `scripts/rw-create-kafka-secrets.sh qa` (idempotent) so the secret carries the new value.

**Trap:** adding only #1 grants `dx__qa_kafka_prefix*` while RisingWave joins
`qa_kafka_prefix*`. Same error, now with a merged PR and a green Octopus deploy behind it —
[[adjacent-step-green-signals]]. Change both or neither.

**Prod gets fixed by the same rule**, which is the point of deriving it rather than
hardcoding: prod's empty `confluent_prefix` yields `dx__risingwave` on both sides.

**Method note:** three repos in, the answer was always "find the repo that owns the
convention". `iaac-confluent-cloud` owns clusters; `ix-kafka-topics-users` owns ACLs;
`risingwave-pipeline` owns the consumer. The bug lived in the gap between the last two, which
is exactly where nobody's tests look. See [[ccloud-registry-master-per-account]].

### 2026-09-11 (late) — RisingWave's Kafka credential is a COPY of a rotating master. Today it matches.

Idris: `op-usxpress-qa/risingwave/kafka` was populated by hand from
**`dx__risingwave-kafka-creds`**, the record `ix-kafka-topics-users` writes for the service
account it creates from `users/risingwave.yml` (named `dx__<prefix>risingwave`, `main.tf:35`).
Same copy-the-master pattern as the schema registry
([[ccloud-registry-master-per-account]]).

**Compared by sha256, no value printed, 2026-09-11 — all six shared fields IDENTICAL:**
`api_key`, `api_secret`, `bootstrap_server`, `rest_endpoint`, `resource_id`,
`service_account`. So the copy is current and **INFRA-1637's stale key is not this one.**

Expected differences: the three `schema_registry_*` fields exist only on the target (added by
`scripts/copy-registry-creds-to-rw.sh` this afternoon); `KAFKA__misc_rotation` exists only on
the source.

⚠️ **The exposure: `ix-kafka-topics-users` runs an `aws_lambda_function` named
`ccloud-kafka-key-rotation`** (seen updating in-place in the 1.8.36 plan, account
937464026810). RisingWave holds a **copy**, so a rotation updates the master and silently
leaves RisingWave behind. The symptom would be SASL auth failing at an arbitrary later date,
looking like a broken cluster rather than a stale credential — and `KAFKA__misc_rotation` on
the master proves the machinery touches this exact record.

**Durable fix (ticket, not tonight):** point RisingWave's ExternalSecret at
`dx__risingwave-kafka-creds` directly instead of a hand-copied record, so a rotation
propagates. Note the casing differs (`KAFKA__` on the master, `kafka__` on the target) and the
master does **not** carry the schema-registry fields — so it is a two-source mapping, not a
straight swap. Prod inherits this shape unless it is fixed first.

**Trap for the comparison itself:** the key prefix differs in CASE between the two records, so
a name-based diff reports everything as different while every value matches. Compare hashes of
VALUES and normalise the key case — a name diff here answers the wrong question.

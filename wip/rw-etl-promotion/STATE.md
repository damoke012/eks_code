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

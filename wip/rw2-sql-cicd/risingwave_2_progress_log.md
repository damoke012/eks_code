# RisingWave-2 CICD — Progress Log

**Project**: On-prem RisingWave CICD pipeline (`risingwave-2` namespace on `op-usxpress-dev` Talos cluster)
**Owner**: On-prem Platform team (Doke)
**Purpose of this doc**: Dated log of completed work + open items. Suitable for status sharing (Steve, Vibin, Idris, Tim). Newest entries at top.

---

## 2026-05-26 — END OF DAY ROUND-UP

A heavy day across two tracks (platform CICD + SQL pipeline). Everything below this section is the detailed dated log. This is the elevator-pitch summary.

### What landed today (chronological)

1. **Platform CICD codification** — iaac-talos PR #29 (commit `e34da91`) merged. The IRSA role, S3 bucket, and inline policy for `risingwave-2` are now Terraform-managed instead of manually created. Octopus release `0.1.0-feat-risingwave-2-irsa-codify.1.140` applied with `TfApply=true`, then flipped back to false. Orphan legacy managed policy (`op-usxpress-dev-risingwave-2-s3`) detached + deleted.
2. **AWS SM secrets split per env** — three new SM paths (`op-usxpress-dev/risingwave-2/{postgres,root,console_license_key}`) created with same values as prod paths; iaac-risingwave-2 commit `85c6790` flipped ExternalSecret references. Tim's prod `risingwave` ns untouched.
3. **License key wired in** — `rw-license-key.yaml` added to `manifests/op-usxpress-dev/kustomization.yaml` resources (commit `225fd7a`). Mystery from prior memory closed: the secret wasn't being "wiped" — Flux just wasn't deploying it because the file was missing from the Kustomization.
4. **Docs repo updated on GitHub** — `variant-inc/iaac-risingwave-cicd` README + INCIDENT_LOG pushed (commit `b837d95`).
5. **Tim sync meeting decoded + memorialized** — Kafka/Mongo architecture, secrets model, environment conventions, Kafka-topics-users branch-wipe gotcha, LDAP auth all captured.
6. **SQL pipeline track started** — `usxpressinc/risingwave-poc` forked to `variant-inc/risingwave-pipeline` (mirror push, all branches + tags). `feat/onprem-rw2-adaptation` branch (commit `72b62f2`) adapts SM paths + IAM role names + archives cloud DX deploy spec.
7. **Discovered `feat/rw_pipeline` was Idris's work**, not Tim's. Commit `b5eaaf2` (2026-05-21). 266-line `pipeline.yaml` with validate → approve → execute pattern.
8. **Tim shared secret + source pattern in Teams** — `CREATE SECRET dev_kafka_prefix WITH (backend='meta') AS 'dx__dev_risingwave_risingwave_dev'`. Captured.
9. **Flyway-on-RW empirical spike** — Tim raised in meeting whether file-change detection was right. Tested Flyway compatibility against RW-2 via port-forward + direct psql. **Flyway INCOMPATIBLE with RW**: rejects `VARCHAR(N)` length specifiers; no read-write transactions. Decision: stay with Idris's file-change approach; extend with RW-compatible tracking table + apply-all bootstrap mode.

### State of all tracks at end of day

| Track | State |
|---|---|
| **Platform CICD (`risingwave-2`)** | ✅ Operational + fully Terraform-managed + SM split + license key wired. Maintenance mode. |
| **AWS resources** | ✅ All TF-managed. Orphan policy deleted. SM paths split per env. |
| **Documentation** | ✅ `iaac-risingwave-cicd` README + INCIDENT_LOG on GitHub. This progress log + memory files current. |
| **Tim's prod `risingwave` ns** | ✅ RUNNING=True, 26d, completely untouched throughout. |
| **SQL Pipeline (`risingwave-pipeline`)** | 🟡 Repo forked + adaptation branch pushed. Approach decided (file-change wins for RW per spike). Blocked on IAM role creation + network strategy + tracking-table extension. |
| **Networking** | 🟡 Doke owes Steve email. Currently NodePort/port-forward only. Not prod-ready. |

### Where to pick up tomorrow morning

**Open at line ~190 of this doc — the "Immediate (this week)" table.** First action: send the Idris coordination message (item #1). Then start on item #2 (IAM role TF). Items 4-5 (GH Environment + repo secrets) can be done in parallel from the GitHub UI while TF is being written.

### Cluster cleanup before signing off (run on WSL)

```bash
# Kill the port-forward we left running for the Flyway spike
pkill -f "kubectl port-forward.*risingwave-2" 2>/dev/null
# Sanity: any stray RW-2 connections from this session
ss -tan | grep :14567 || echo "Clean"
# Remove the spike scratch dir if desired (optional)
rm -rf ~/flyway-rw-spike
```

---

## 2026-05-26 — SQL pipeline fork + adaptation (evening session)

### Major progress today on the SQL pipeline track

After the Tim sync meeting and on user direction "lets begin the work," we executed the first major item from the meeting backlog: **fork Tim's SQL pipeline POC and adapt it for our on-prem cluster**. This is the data-flow companion to the platform CICD track (`risingwave-2`) we finished earlier in the day.

#### What we did
1. **Cloned `usxpressinc/risingwave-poc` for read-only inspection**. Resolved SAML SSO authorization for the `usxpressinc` org via `gh auth refresh`.
2. **Surveyed the repo end-to-end**:
   - Three layers: pipeline file convention (`pipelines/<entity>/{100-source,200-ingest,300-transform,400-sink}.{rw,sql}`); local Docker Compose dev runtime; PowerShell deploy script (`deploy.ps1`).
   - Latest CICD work lives on `feat/rw_pipeline` branch — a 266-line GHA workflow (`pipeline.yaml`) implementing validate → manual approval → execute, with SQL guardrails (blocks DROP/TRUNCATE/DELETE-no-WHERE/injection), AWS OIDC for SM secrets pull, and psql execution against external RW + Postgres.
   - **Important: `feat/rw_pipeline` was authored by Idris (commit `b5eaaf2`, dated 2026-05-21)** — not Tim. This was already Idris's work-in-progress for the SQL pipeline track, sitting in Tim's repo.
   - `.variant/deploy/deploy.yaml` is the cloud DX (terraform-variant-apps) deployment spec for Tim's prod — auto-provisions cloud-side Kafka topics + IRSA SA via the USXpress cloud Octopus space. **Not applicable for on-prem fork.**
   - `.github/workflows/build.yaml` pushes a container artifact to cloud Octopus on every branch push. **Likely also not applicable for on-prem.**
3. **Forked into `variant-inc/risingwave-pipeline`** (internal) via `git push --mirror`. All 7 upstream branches and 6 tags preserved. PR refs from upstream rejected as expected (hidden refs).
4. **Created `feat/onprem-rw2-adaptation` branch off `feat/rw_pipeline`** with these adaptations (commit `72b62f2`):
   - `pipeline.yaml`: AWS role `gha-op-usxpress-dev-risingwave-poc-secrets` → `gha-op-usxpress-dev-risingwave-pipeline-secrets`; SM paths `op-usxpress-dev/risingwave/{postgres,root}` → `op-usxpress-dev/risingwave-2/{postgres,root}`.
   - `README.md`: fork banner crediting Tim's upstream + Idris's GHA work; URL rebrand; project structure name updated.
   - `.variant/deploy/deploy.yaml`: moved to `archive/_unused_dx_deploy.yaml.bak` with an `archive/README.md` explaining why (not deleted — keep for history).
5. **Pushed `feat/onprem-rw2-adaptation` to origin**. Did NOT open PR yet — Idris should review since this extends his work.

#### Bonus capture from Teams while we were working
Tim shared in Teams the exact `CREATE SECRET` + `CREATE SOURCE` pattern we asked about in the meeting. Preserved in [tim_meeting_2026_05_26_sql_pipeline](memory file). Key example:

```sql
CREATE SECRET dev_kafka_prefix WITH ( backend = 'meta' ) AS 'dx__dev_risingwave_risingwave_dev';

CREATE SOURCE brand_source_kafka (...)
WITH (
  topic = 'dev_brand_management_cdc_brand_avro',
  connector = 'kafka',
  properties.bootstrap.server = '...',
  properties.sasl.username = '...',
  properties.sasl.password = '...',
  group.id.prefix = secret dev_kafka_prefix,
  scan.startup.mode = 'earliest'
);
```

Idris confirmed in chat that `dx__dev_risingwave_risingwave_dev` is the value `dev_kafka_prefix` resolves to — generated by the DX cloud Octopus deploy.

#### State of `variant-inc/risingwave-pipeline` at end of day
- master: mirror of upstream master (28ea530, "update gitignore")
- feat/rw_pipeline: Idris's GHA pipeline (b5eaaf2)
- feat/onprem-rw2-adaptation: our adaptation on top of feat/rw_pipeline (72b62f2)
- 5 other upstream branches preserved as-is
- 6 tags (v0 through v0.0.4) preserved

### What's blocking the workflow from actually running

We have the workflow file in place, but it can't execute until:

1. **IAM role `gha-op-usxpress-dev-risingwave-pipeline-secrets`** doesn't exist yet — needs creating in iaac-talos (Terraform module pattern, similar to the risingwave-2 IRSA role we just shipped). Trust must allow GitHub Actions OIDC from `repo:variant-inc/risingwave-pipeline`. Inline policy grants `secretsmanager:GetSecretValue` on `op-usxpress-dev/risingwave-2/{postgres,root}`.
2. **Repo secrets** — `RISINGWAVE_HOST`, `RISINGWAVE_PORT`, `POSTGRES_HOST`, `POSTGRES_PORT` need values in repo settings. **Blocked on network strategy** (see #3).
3. **Network path from GitHub-hosted runner → in-cluster RW-2 frontend**. Three options to choose between:
   - **NodePort exposure** of RW-2 frontend on worker IPs (analogous to Tim's prod NodePort 32567). Quickest, reversible.
   - **Self-hosted runner inside the cluster** (uses internal Service DNS). More secure, no external exposure needed.
   - **Full ingress** (Istio Gateway + external-dns + TCP routing). Proper long-term path but blocked on network team turnaround.
4. **GitHub Environment `pipeline-approval`** on the repo — required reviewers configured. Quick GH UI setup.
5. **`.github/workflows/build.yaml` decision** — disable/delete (cloud Octopus push isn't relevant for on-prem) or keep as no-op until we figure out the on-prem container artifact story.

### Coordination needed (action: Doke)
- Message to Idris (drafted; pending send): heads-up about the fork + invite to review `feat/onprem-rw2-adaptation`. He owns the original work + the secrets pipeline scope.

### Flyway-on-RW empirical spike — DECIDED (later same evening)

Ran a fast empirical compatibility test against RW-2 via port-forwarded `risingwave-frontend` svc:4567. Goal: see if Flyway's bookkeeping shape works on RW. Couldn't download the Flyway tarball (corporate network throttled maven.org to 30KB/s, ETA 21+ days), so tested directly via psql with the exact DDL Flyway would issue.

**Result: Flyway is INCOMPATIBLE with RW.** Two hard blockers:

1. **`VARCHAR(N)` length specifiers rejected.** Flyway's schema history table uses `VARCHAR(50)`, `VARCHAR(200)`, etc. RW errors with `sql parser error: expected ',' or ')' after column definition`. RW only accepts unbounded `VARCHAR`. Schema history can't be created without forking Flyway itself.
2. **No read-write transactions in RW.** RW prints `NOTICE: Read-write transaction is not supported yet`. Flyway's atomic-apply guarantee (BEGIN → migrate → COMMIT, or ROLLBACK on failure) is moot — RW runs everything in autocommit. Failed migrations leave half-applied state with no rollback.

Bonus weirdness: even a basic `BEGIN; CREATE TABLE; INSERT; COMMIT; SELECT` returned `(0 rows)` after the INSERT reported `INSERT 0 1`. RW's table-vs-source semantics + autocommit + eventual visibility don't behave the way Flyway expects.

Liquibase + Atlas almost certainly hit the same walls (both use bookkeeping tables with VARCHAR length specifiers, both assume transactional DDL execution).

### DECISION: stay with Idris's file-change-detection workflow + extend

Idris's `feat/rw_pipeline` approach actually sidesteps every issue we just hit:
- No schema history table → no VARCHAR(N) problem
- No BEGIN/COMMIT → aligns with RW's autocommit-only behavior
- Each file applied independently → no atomicity assumption

Tim's concerns from the meeting (drift detection, fresh-env bootstrap, history) are still legitimate. The fix is **extend Idris's workflow**, not replace it:

1. **Lightweight RW-compatible tracking table** — `pipeline_applied_migrations(filename VARCHAR, checksum VARCHAR, applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, applied_by VARCHAR, success BOOLEAN)`. INSERT-only, no UPDATE, no PRIMARY KEY constraint, no VARCHAR(N). Doubles as audit log + drift detector via checksum comparison.
2. **"Apply-all" bootstrap mode** — workflow input parameter triggers full-bootstrap (reads all files in sorted order, skips those already in the tracking table with success=true). For new env bring-up.
3. **Global filename ordering convention** — recommend (not enforce) cross-entity coordination via a 3-digit global prefix. Idris's per-entity `100-200-300-400` is fine for intra-entity.

### What unblocks now
The decision unblocks all the previously-on-hold infra work:
- Create `gha-op-usxpress-dev-risingwave-pipeline-secrets` IAM role in iaac-talos TF (next session)
- Decide network strategy (file-change works from either GHA-hosted runner via NodePort OR self-hosted runner in-cluster)
- Configure `pipeline-approval` GitHub Environment
- Set repo secrets RISINGWAVE_HOST/PORT, POSTGRES_HOST/PORT

### IMPORTANT — open architectural question from Tim sync transcript (HISTORICAL — now resolved by the spike above)

Re-reading the meeting transcript surfaced something we initially under-weighted. Tim said:

> "I've been looking at some different ways of doing the database CI/CD… Detecting a file change. I don't know if that's necessarily the way to go. Maybe it is. But there are some more… there are some different options out there, like **Flyway** that I do believe has a free version. And then, yeah, I've actually lost the link that I'm searching for."

**Tim is actively questioning whether file-change detection (Idris's current `pipeline.yaml` design) is the right CICD pattern for the SQL pipeline.** This matters because:

- File-change detection isn't idempotent against `CREATE SOURCE` / `CREATE MATERIALIZED VIEW` (RW errors when objects already exist).
- It doesn't handle fresh-env bootstrap (a new `risingwave-qa` would need ALL files run in order, not just a git diff).
- No drift detection if a file is edited in place vs. a new versioned migration added.
- No global cross-entity ordering (Brand → employee dependencies).
- No "what was applied when" history table.

Alternatives to consider:
- **Flyway Community** (Tim's lead candidate) — free, mature, versioned migrations with checksum tracking. RW speaks pg-wire so Postgres dialect likely works for most DDL.
- **Liquibase Community** — similar, XML/YAML oriented.
- **Atlas (ariga)** — modern, declarative, Postgres dialect, gaining traction in 2026.
- **Custom in-RW history table** — most fit-to-purpose but most engineering cost.
- **dbt** — already vetoed by Vibin back in March (per `vibin_decisions_march31` memory). Do NOT propose.

**Recommendation**: pause more infra commits (IAM role, repo secrets, network strategy) until we settle the approach question. The IAM scope and network strategy might differ depending on which tool we adopt. Specifically:
1. Ask Tim what the "lost link" was — he's our subject-matter expert on what RW can support.
2. Do a 30-min Flyway-on-RW spike: try running `flyway info` / `flyway migrate` against RW's frontend (pg-wire on port 4567 in cluster, NodePort externally). See if Flyway's `flyway_schema_history` table is acceptable to RW.
3. Sync with Idris on whether to evolve his file-change workflow or pivot to Flyway/equivalent.

This is added to the next-steps tables as the gating decision.

---

## 2026-05-26 — Next steps (consolidated, end-of-day, refreshed)

Refreshed after the fork session. Items moved out of "Immediate" as we completed them.

### Immediate (this week — actively in flight)

**Refreshed after the Flyway-on-RW spike decision. All HOLDs lifted.**

| # | Track | Item | Owner | Notes |
|---|---|---|---|---|
| 1 | SQL Pipeline | **Message Idris**: (a) heads-up about the fork + review request for `feat/onprem-rw2-adaptation`, (b) share Flyway spike results, (c) propose extending his `pipeline.yaml` with RW-compatible tracking table + apply-all bootstrap | Doke | He owns the file-change approach; we have empirical evidence it's the right call for RW. |
| 2 | Platform Infra | **Create `gha-op-usxpress-dev-risingwave-pipeline-secrets` IAM role in iaac-talos TF** with OIDC trust for `repo:variant-inc/risingwave-pipeline:*` and inline SM read on `/risingwave-2/{postgres,root}` | Doke | Pattern identical to risingwave-2 IRSA role we shipped earlier today (PR #29). Same Octopus + TfApply gating. |
| 3 | SQL Pipeline | **Decide network strategy** for GHA-hosted runner → RW-2. NodePort exposure (quick, matches Tim's prod pattern) or self-hosted runner in-cluster (more secure). | Doke + Idris | Both work with file-change approach. NodePort is faster; self-hosted is cleaner. |
| 4 | SQL Pipeline | Configure GitHub Environment `pipeline-approval` on `variant-inc/risingwave-pipeline` with required reviewers (Doke + Idris at minimum) | Doke (GH UI) | Quick — Settings → Environments → New environment. |
| 5 | SQL Pipeline | Set repo secrets RISINGWAVE_HOST, RISINGWAVE_PORT, POSTGRES_HOST, POSTGRES_PORT once network strategy chosen | Doke (GH UI) | Depends on #3. |
| 6 | SQL Pipeline | **Design + sketch the tracking-table + apply-all extension** to Idris's `pipeline.yaml`. Sample table schema in the open-question memory. | Doke (sketch) + Idris (review/implement) | Sketch in a new branch off `feat/onprem-rw2-adaptation`. |
| 7 | SQL Pipeline | Disable or delete `.github/workflows/build.yaml` (cloud Octopus container push — not relevant for on-prem) | Doke | Follow-up PR after env retargeting + tracking-table land. |
| 8 | Networking | Draft + send email to Steve with the network team research ask (external SQL ingress for QA/staging/prod) | Doke | Currently NodePort/port-forward only — not prod-ready. |
| 9 | Access | Check what Octopus projects Idris is missing; help Steve scope his Octopus admin access | Doke + Steve | Octopus auto-provisioning unclear who admins. |

### Completed today (moved from "Immediate")

| # | Item | Where landed |
|---|---|---|
| ✅ | Fork `usxpressinc/risingwave-poc` → `variant-inc/risingwave-pipeline` | https://github.com/variant-inc/risingwave-pipeline |
| ✅ | Adapt SM paths + IAM role names for our on-prem env on `feat/onprem-rw2-adaptation` | commit `72b62f2` |
| ✅ | Got Tim's secret + source smoke-test example | Captured in Teams + this log |

### Short-term (next 1-2 weeks)

| # | Track | Item | Owner | Notes |
|---|---|---|---|---|
| 9 | SQL Pipeline | Smoke-test the SQL pipeline end-to-end using Tim's `CREATE SECRET dev_kafka_prefix WITH (backend='meta')` example via the GHA workflow once IAM role + repo secrets are in place | Doke + Idris | Tim already gave us the example today; just need infrastructure ready. |
| 10 | SQL Pipeline | Design Kafka topic isolation strategy for `risingwave-qa`. Constraint: only one non-prod Confluent cluster exists, shared with dev. Prefix-based naming is the obvious option. | Doke + Tim collaboration | Don't propose new Confluent clusters — Tim's model is 2 clusters total. |
| 11 | SQL Pipeline | Understand + document the `variant-inc/Kafka-topics-users` repo workflow and the branch-wipe gotcha. Plan coordination model before our team pushes to it. | Doke (read repo with Tim's help) | Tim warned: "don't look at it, it'll make your head explode" — but offered to walk through. |
| 12 | Platform Infra | Codify `local-path-storage` namespace PodSecurity label as Terraform via `kubernetes_labels` resource | Doke | K8s provider already configured in iaac-talos. Low-priority — runtime stable, hygiene only. |
| 13 | Platform Infra | Worker memory expansion 4Gi → 8Gi (raises compute headroom for RW-2; matches Tim's prod sizing) | Doke | Per `onprem_phase1_phase2_memory_expansion_plan` memory. **This weekend.** Requires VM reboots — coordinate with Idris/Tim. |
| 14 | Secrets | Rotate postgres password away from bitnami default `risingwave/risingwave` on both prod and risingwave-2 SM paths (now independent post-split) | Doke + Tim coordination for prod | Pre-prod-readiness hardening. |

### Medium-term (this month, blocked by external)

| # | Track | Item | Owner / Blocker | Notes |
|---|---|---|---|---|
| 15 | SQL Pipeline | Open PR `feat/onprem-rw2-adaptation` → `master` on `variant-inc/risingwave-pipeline` AFTER Idris signoff + IAM role + repo secrets land | Doke + Idris | Currently the branch lives unmerged on origin (commit `72b62f2`). |
| 16 | Networking | Receive answer from network team on external SQL ingress design (LDAP-backed). Then implement: Istio Gateway + external-dns + TCP routing OR equivalent. | Blocked on Steve's network team turnaround | Followup to item #7 (Steve email). |
| 17 | SQL Pipeline | Once Idris's secrets pipeline is working in RW-2, write the README guide for SQL developers: minimum info required (topic name, source/sink target), everything else abstracted via `SECRET <name>` | Doke (after #9) | Tim emphasized: "we need a README guiding the developer on the minimum thing they have to create." |
| 18 | Platform Infra | Codify per-env IAM role/policy/bucket as a reusable TF module (instead of inline `risingwave-2-role.tf`) | Doke | Only needed when standing up a second env (QA, staging) — not urgent. |
| 19 | SQL Pipeline | Stand up `risingwave-qa` environment (separate namespace, separate IAM role + S3 bucket, separate SM secrets) | Doke + Idris | Sequential after RW-2 stability + secrets pipeline. Doke flagged in the meeting: "still some cleanup we need in dev environment" before QA. |

### Backlog (no urgency / monitoring only)

| # | Track | Item | Owner | Notes |
|---|---|---|---|---|
| 20 | SQL Pipeline | Watch for RisingWave shipping the compound-secret feature Tim requested. If it ships, simplifies our SM design (one AWS SM entry per backend instead of one-per-field) | Doke (monitor RW Slack + their GitHub) | Tim said RW is "blowing him up" with engagement — likely shipping soon. |
| 21 | SQL Pipeline | When ready, switch Tim's prod `risingwave` namespace to be CICD-driven (vs. manually deployed today). Coordinate with Tim before DNS / source-of-truth cutover | Doke + Tim | Tim is supportive but wants notice before any DNS flip. |
| 22 | Documentation | Update `iaac-risingwave-cicd/README.md` once the SQL pipeline track has a working end-to-end deploy — add the SQL pipeline track to that doc | Doke | Right now the README is focused on the platform CICD only. |
| 23 | Documentation | Push `risingwave_2_progress_log.md` (this file) into `iaac-risingwave-cicd/docs/` if we want enterprise-visible status tracking, or keep local | Doke decision | Either way, keep dating entries. |

### Track-by-track summary (updated post-fork)

- **Platform CICD track** (`risingwave-2` ns, `iaac-risingwave-2`, `iaac-talos` IRSA codification): **DONE**. Maintenance mode going forward (image bumps, helm upgrades, env additions).
- **Secrets track** (AWS SM → RW pipeline): IN FLIGHT, Idris leading. Tim's smoke-test sample captured today.
- **SQL Pipeline track** (data flow, Kafka/Mongo connectors, SQL): **FORKED + ADAPTED**. `variant-inc/risingwave-pipeline` exists, `feat/onprem-rw2-adaptation` (commit `72b62f2`) ready for Idris review. Blocked on IAM role creation + network strategy + repo secrets before workflow can actually execute.
- **Networking track** (external SQL ingress, prod-ready DNS): Doke owes Steve an email; blocked on network team turnaround after that.
- **Documentation track**: iaac-risingwave-cicd README + INCIDENT_LOG up to date. This progress log is now the running status doc.
- **Hardening track** (postgres password rotation, local-path Terraform, memory expansion): backlog, no urgency on items 8 + 10. #9 (memory) is this weekend.

### Where Tim's stuff lives (recap from meeting)
- SQL pipeline PoC: `usxpressinc/risingwave-poc` (NOTE: `usxpressinc` org, not `variant-inc`)
- Kafka topics repo: `variant-inc/Kafka-topics-users` (the one with the branch-wipe gotcha)
- Tim's prod RW: `risingwave` namespace on op-usxpress-dev (untouched by us, RUNNING 26d)
- Confluent Cloud: 2 clusters (non-prod, prod). Non-prod shared by dev + qa + staging.
- Mongo Atlas: 2 clusters. Env-prefixed databases in non-prod (`brand-dev`, `brand-qa`); unprefixed in prod.
- Postgres auth: LDAP.

---

## 2026-05-26 — Tim sync meeting (afternoon) — SQL pipeline + secrets + Kafka + Mongo architecture

### Attendees
- Steve (manager, networking lead)
- Tim Preble (owns prod RW + SQL pipelines)
- Idris (platform peer)
- Doke (on-prem platform — me)

### Key outcomes / facts captured

#### Tim's existing SQL pipeline POC repo
- **`usxpressinc/risingwave-poc`** — Tim's existing PoC repo (note: `usxpressinc` org, not `variant-inc`). Contributors: Tim Preble + Garrett MacKay. Languages: PowerShell 59% / Shell 39% / PLpgSQL 2%. Latest commit 4 months ago. v0.0.4 latest release Jan 23. Build status: Push-to-Octopus passing, Pre-Commit failing.
- Pipeline architecture per his README: `Kafka topics (Confluent Cloud) → RisingWave (streaming analytics) → MongoDB Atlas (collections)`.
- **Action**: fork this into `variant-inc` org so platform team owns it. **This is the next major piece of work** — bring SQL pipeline IaC into platform control + iterate from there. (Idris confirmed he'll point us there.)

#### Tim's current secrets implementation (today, prod)
- Uses **RisingWave's built-in secret manager**.
- Secrets are stored in **RW's backing postgres database, port 8432** (separate from RW's external SQL port 4567).
- Encrypted at rest (Tim believes salted/encrypted by RW; not visible in plaintext when queried).
- Pattern: developer writes SQL `CREATE SECRET meta_user WITH (...)`, then later references it inline: `properties.username = SECRET meta_user`.
- The values themselves currently live in RW's postgres — not in AWS SM yet (for prod).

#### Tim's RW feature request (filed; RW responding actively)
- Today, creating a Kafka source requires the developer to specify many fields: bootstrap.server, schema.registry.url, schema.registry.username, schema.registry.password, security.protocol, sasl.mechanism, sasl.username, sasl.password, etc.
- Tim asked RW to support **compound secrets**: ONE secret name that bundles all of these. So a developer writes `SECRET kafka_non_prod` and RW expands to all the underlying fields at runtime.
- RW responded enthusiastically. Tim is "getting blown up" with RW engagement on it.
- **Implication for us**: if RW ships this, our CICD-managed secrets become much cleaner — one AWS SM entry per backend (kafka_non_prod, kafka_prod, mongo_non_prod, mongo_prod, etc.) instead of one-per-field.

#### Idris's plan for secrets abstraction (the work this week)
- AWS SM → RW secret via CICD pipeline.
- E.g. `kafka_non_prod` secret already exists in AWS SM → pipeline pulls it → creates as RW secret inside RW's metadatabase → SQL code can reference by name.
- This is what Idris is building next.
- Tim is supportive: "whatever you guys want to do" + offered to give example secret + how to execute as smoke test.

#### Confluent Cloud Kafka — environment model (CRITICAL nuance)
- Confluent has **only two environments**: `non-prod` and `prod`.
- `non-prod` is shared by what Octopus calls dev, staging, and qa. Tim doesn't really use Octopus's `staging` env.
- **Implication for our QA env**: when we stand up `risingwave-qa`, the underlying Confluent cluster will still be the same `non-prod` cluster Tim's dev uses. We need to think about Kafka topic isolation — likely via topic-name prefixes (e.g., `qa.timmyp.cdc.employee.json` vs `dev.timmyp...`) rather than separate clusters.
- **Prod cutover**: changes config to point to prod cluster, manager approval, merge to main, deploy via Octopus. Tim owns this; platform involvement only during this current pre-prod transition period.

#### Confluent Cloud Kafka — the GitHub branch-wipe gotcha (DO NOT ignore)
- Kafka topics + users + ACLs managed via a GitHub repo: **`variant-inc/Kafka-topics-users`** (Tim's wording).
- Workflow: create branch off master, add topics/users/mappings, push. GitHub Action provisions to non-prod.
- **The problem**: pushes from one branch wipe out everything that was added from another branch if the other branch isn't merged to master yet. Tim's mitigation: created a `TimmyP` parent topic to hold his test stuff so it doesn't get nuked.
- Tim warned us explicitly: "yeah, don't look at it, it'll make your head explode." But also: "I can give you some help with this and walk you through it when you're ready."
- **Implication for us**: when we start managing Kafka topics for `risingwave-2` or `risingwave-qa`, we need a coordination strategy — either always rebase before push, or coordinate via Slack/Teams, or solve the underlying repo issue. Don't naively push into this repo.

#### MongoDB Atlas — environment model (much cleaner than Kafka)
- Also two envs: prod + non-prod.
- Inside non-prod, **databases are prefixed** with env name: e.g. `brand-dev`, `brand-qa`.
- In prod, no prefix: just `brand`.
- The prefixing logic is driven by an **Octopus variable `environment_short`** — set differently per environment scope (dev/qa/staging share one set, prod has its own).
- Tim said the Mongo side is "a lot easier to manage than Kafka because Kafka [topics get] overwritten all the time."
- Implementation for any deployment: from application/SQL side (Tim's), the connection string uses the env-prefixed name.

#### Postgres auth on RW backing store
- **LDAP** (confirmed by Idris).
- This affects how we expose external SQL access — LDAP-backed users mean we have more flexibility than a static password, but still need a proper ingress path.

#### Networking — still open
- I (Doke) owe Steve an email outlining what we need network team to research.
- External SQL access for QA/staging/prod: currently NodePort or port-forward, neither is prod-ready.
- This is unblocked work for me, just hasn't been done; will batch with the other on-prem networking ask.

#### Octopus access for Idris
- Idris has Octopus account but can't see enough projects.
- Steve to figure out who admins access (turning out to likely be the platform team going forward).
- Followup for Steve, but worth me checking what Idris is missing so we can scope it.

### Action items from this meeting

| # | Item | Owner | Priority |
|---|---|---|---|
| 1 | Fork `usxpressinc/risingwave-poc` into `variant-inc` (or work directly with it under license from Tim) — start building the SQL pipeline CICD here | Doke + Idris | NEXT MAJOR TASK |
| 2 | Build AWS SM → RW secret pipeline (Idris already started) | Idris | This week |
| 3 | Get example secret + execution sample from Tim for smoke-testing the pipeline | Doke (ask Tim) | This week |
| 4 | Decide Kafka topic isolation strategy for `risingwave-qa` (prefix-based, separate cluster, or other) | Doke + Tim collaboration | When standing up QA |
| 5 | Email Steve with networking team research ask (external SQL ingress, what kind, what doors need opening) | Doke | This week |
| 6 | Sort Idris's Octopus visibility | Steve + Doke | Low-medium |
| 7 | Watch for RW shipping compound-secret feature — if it lands, simplifies our SM design considerably | Doke (monitor RW Slack/issue) | Background |

---

## 2026-05-26 — RW-2 CICD codification + SM split + license-key wire-up

### What is RW-2 and why does it exist
`risingwave-2` is a CICD-driven, GitOps-managed copy of the RisingWave stack on `op-usxpress-dev`. It is isolated from the production `risingwave` namespace (operated by Tim/Idris) and serves as the platform team's test bed for operator upgrades, image bumps, helm chart changes, and future SQL pipelines. Promotion is forward-only: changes validated here are PR'd upstream to Tim/Idris's `iaac-risingwave-onprem` repo.

### Completed today

#### 1. Terraform codification of all AWS resources
Before today, the IRSA role + S3 bucket + IAM policy supporting `risingwave-2` lived in AWS but were not in any code repo (manual `aws iam create-*` from the initial bring-up). This is now fully Terraform-managed.

- **iaac-talos PR #29** opened against `feature/op-usxpress-dev` (the on-prem deployable branch).
- Three new resources in `deploy/terraform/modules/irsa/risingwave-2-role.tf`:
  - `aws_s3_bucket.risingwave_2_data` — bucket `risingwave-data-op-usxpress-dev` with full public access block, ManagedBy=terraform tag
  - `aws_iam_role.risingwave_2` — IRSA role `op-usxpress-dev-risingwave-2`, trust pinned to `system:serviceaccount:risingwave-2:risingwave` via the CloudFront-served OIDC
  - `aws_iam_role_policy.risingwave_2_s3` — inline policy `s3-hummock` granting bucket access
- Three new outputs in `deploy/terraform/modules/irsa/outputs.tf` (role ARN, bucket name, bucket ARN).
- Root-module `import` blocks added in `deploy/terraform/risingwave-2-imports.tf` (had to be in root, not child module — TF 1.5+ constraint) to bring pre-existing AWS resources into TF state without recreating them.
- Octopus release `0.1.0-feat-risingwave-2-irsa-codify.1.140` applied with `TfApply=true`, then `TfApply` flipped back to `false` (safety default).
- PR #29 squash-merged: commit `e34da91` on `feature/op-usxpress-dev`.

#### 2. Cleanup of legacy IAM policy
The pre-codification `risingwave-2` IAM role was attached to a standalone managed policy `op-usxpress-dev-risingwave-2-s3` created by `aws iam create-policy` during the manual bring-up. The TF inline policy now grants the same actions.
- Verified inline policy grants identical actions to the managed policy.
- Detached the managed policy from the role.
- Deleted the managed policy.
- RW-2 pods stayed healthy throughout (no restarts).

#### 3. AWS Secrets Manager split per environment
Before today, RW-2 ExternalSecrets pulled from `op-usxpress-dev/risingwave/*` paths — the same SM secrets that Tim's production also reads. This created a coupling where rotating one environment's password would have affected both.

- Created three new SM secrets at `op-usxpress-dev/risingwave-2/*`:
  - `postgres` (username, password)
  - `root` (password)
  - `console_license_key` (RW_LICENSE_KEY JWT)
- All three were created with the **same values** as the prod paths — same-value migration to enable later independent rotation without any current pod churn.
- Updated three manifests in `iaac-risingwave-2` to point at the new SM paths (`pg-externalsecret.yaml`, `rw-root-bootstrap-job.yaml`, `rw-license-key.yaml`). Commit `85c6790`.
- After Flux reconcile: `pg-credentials` + `rw-root-credentials` ExternalSecrets re-synced with identical K8s secret values → zero pod restarts.
- Tim's production `risingwave` ns is untouched — his manifests still reference the original `op-usxpress-dev/risingwave/*` paths.

#### 4. License-key ExternalSecret wired into Flux
During the SM split, we discovered that the `rw-license-key` Secret had not been getting deployed in `risingwave-2`. Root cause: the file `manifests/op-usxpress-dev/rw-license-key.yaml` existed in the repo but was **not listed in `kustomization.yaml`'s `resources:` list**. Flux therefore never applied it.

This also explains a long-standing mystery in production: the prod `rw-license-key` Secret had been observed disappearing periodically and the "deleter" was unknown. The real cause for at least the RW-2 case was: nothing was creating it.

- Confirmed Idris's license key value matches what's already in our SM path.
- Added `- rw-license-key.yaml` to the resources list in `manifests/op-usxpress-dev/kustomization.yaml`. Commit `225fd7a`.
- Flux reconciled. `rw-license-key` ExternalSecret is now SecretSynced=True. K8s Secret created with key `RW_LICENSE_KEY`.

#### 5. Documentation repo updated on enterprise GitHub
- `variant-inc/iaac-risingwave-cicd` (the platform team's owned docs repo for this pipeline) updated to reflect all of the above.
- Initial commit `7402d4a` + today's update commit `b837d95` are on `main`.
- Contents: architecture diagram, components table, repos-and-their-roles, end-to-end change flow, new-environment playbook (templates included), update cadence table, lessons learned (15 incident-log entries), open followups.

### State of `risingwave-2` at end of day
- RisingWave CR: `RUNNING=True` (5h+ uptime).
- 4 ExternalSecrets in the namespace, all SecretSynced=True: `pg-credentials`, `rw-root-credentials`, `rw-license-key`, plus prometheus' own.
- Postgres meta-store healthy (bitnamilegacy chart 16.4.0, no NetworkPolicy blocking ambient HBONE).
- IRSA pulling from dedicated S3 bucket `risingwave-data-op-usxpress-dev`.
- All AWS resources Terraform-managed; all manifests under Flux GitOps reconciliation.

### State of production `risingwave` (Tim) — untouched
- RW CR: `RUNNING=True` (26d uptime, unchanged through all of today's work).
- 7 pods Running.
- `risingwave-frontend-lb` NodePort 32567 still exposed.
- Tim's `iaac-risingwave-onprem` repo not touched. SM paths he reads still in place.

### Open items going forward

| # | Item | Owner / blocker | When |
|---|---|---|---|
| 1 | Stand up `risingwave-pipeline` repo for Kafka/Mongo connector configs + SQL pipeline definitions | Idris (creating under `variant-inc` org) | Pending Idris |
| 2 | Codify `local-path-storage` namespace PodSecurity label as Terraform (`kubernetes_labels` resource — K8s provider already configured in iaac-talos) | Platform | Low priority — runtime is stable |
| 3 | Rotate postgres password away from bitnami default (`risingwave/risingwave`) on both prod and risingwave-2 SM paths (now independent post-split) | Platform + coordinate with Tim for prod | Hardening — pre-prod-readiness |
| 4 | Worker memory expansion 4Gi → 8Gi (raises compute headroom for RW-2; matches Tim's prod sizing) | Platform | This weekend |
| 5 | Codify per-env IAM role/policy/bucket pattern as a reusable TF module instead of inline `risingwave-2-role.tf` | Platform | Once a second non-prod env (QA, staging) is requested |
| 6 | Expose RW-2 frontend SQL endpoint externally (NodePort/Gateway + external-dns) | Platform | When data team wants direct access to RW-2 for pipeline dev |

### Stakeholder map
- **Steve Duck** (Networking) — owns ingress + DNS for on-prem; not directly involved in RW-2 internal connectivity, but needed if/when external SQL access is wired.
- **Vibin** — Cloud team lead; aware of the on-prem RW track. RW-2 is on-prem owned per his prior direction.
- **Tim Preble** (Data Eng) — owns production `risingwave` namespace. Not affected by today's work. Will receive forward-promoted changes via PR once they validate in RW-2.
- **Idris Fagbemi** — Platform peer; owns Phase 1 RW platform and currently building `risingwave-pipeline` repo. Cluster-admin on op-usxpress-dev.
- **Doke** — On-prem platform owner; lead for RW-2 + this CICD pipeline.

### Where the docs live
- **`variant-inc/iaac-risingwave-cicd`** — architecture + ops runbooks + new-env templates + incident log. THE place to send for "how does RW-2 work."
- **`variant-inc/iaac-risingwave-2`** — manifests Flux deploys (data plane source of truth).
- **`variant-inc/iaac-talos`** (`feature/op-usxpress-dev`) — cluster Terraform; includes the codified RW-2 IAM/S3 as of today.
- **`variant-inc/iaac-talos-flux-cluster`** (`master`) — cluster bootstrap; `clusters/bm-dev/flux-system/infra.yaml` defines the `risingwave` Kustomization that targets `iaac-risingwave-2`.
- **`variant-inc/iaac-risingwave-onprem`** — Tim/Idris production source (read-only for platform team).

---

## How to use this log

- Add a new dated section at the **top** for each working session that produces meaningful state change.
- Keep entries action-oriented: what changed in the cluster, what's now codified, what's still pending.
- Avoid duplicating the architecture — link to `iaac-risingwave-cicd/README.md` for that.
- This file is the right thing to paste to Steve / Vibin / leadership when they ask "what's the state of RW-2?"

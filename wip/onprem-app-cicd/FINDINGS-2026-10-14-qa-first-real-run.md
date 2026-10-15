# QA ran the real pipelines for the first time — 2026-10-14 18:13Z

Argo `Synced / Succeeded`. Eight files in `pipeline_applied`, `applied_by = argocd-qa`:
`100-Brand/{100-sources,200-ingest,300-transform-flat}.rw` and all five
`200-ActiveResource/*`. The only older rows are `Brand/` + `canary/` from 2026-09-11.

## 🔑 ROOT CAUSE of QA's divergence — a missing `image.repository`

`values-qa.yaml` had **no `image.repository`**, so it inherited the chart default
`risingwave/etl-pipeline` while dev sets `risingwave/poc-pipeline`. **Two different build
pipelines.** QA discovered 25 files where dev discovered 24; exclusions written against the
repo tree could never match. `promote` feeds dev from poc-pipeline, `promote-to-qa` feeds QA
from etl-pipeline — the "one digest dev→QA→prod" model was never what the machinery did.

⚠️ I then moved QA's **digest** without its **repository** and produced `ImagePullBackOff` +
`ImageNotFoundException` — gate 5 of [[delivery-is-a-relay-of-nine-gates]], verbatim. The two
values change together or not at all.

## What it took (PRs 117, 118, 119, 120)

| PR | Change |
|---|---|
| #117 | 12 config keys, `EXCLUDE_STRICT`, corrected `EXCLUDE_RE`, 7 Kafka ExternalSecret entries |
| #118 | digest → dev's proven `4553550446f9` |
| #119 | **`image.repository` → poc-pipeline** (the actual root cause) |
| #120 | exclude `100-Brand/001-prescript.sql` |

## Traps measured today

1. **`refresh=hard` is NOT a sync.** When the app reads `Synced`, a refresh finds no diff,
   runs no hook, creates no pod. Cost two round trips. Trigger a sync by writing `.operation`.
2. **An identical `.operation` patch is a no-op.** `kubectl patch` reports `(no change)` and
   Argo does nothing. Vary a field (`initiatedBy.username` with a timestamp).
3. **`argocd.argoproj.io/hook-finalizer` deadlocks.** Argo holds it while the operation is
   Running; the operation waits for the hook. Job sat `Terminating` 90 minutes. Recovery:
   force-delete the pod, then `patch job -p '{"metadata":{"finalizers":null}}'`.
4. **`argocd app terminate-op` → PermissionDenied** with the CLI session on this box; the
   kubectl equivalent is removing `/operation`, and that too was rejected here.
5. **A `.sql` file routes to the app database** and requires `POSTGRES_ENTITY_*` +
   `POSTGRES_SERVER` **even with no placeholders in it**. `001-prescript.sql` is
   `/* TEST FILE */` and still blocked the whole run.
6. **The applier rejects EMPTY as well as missing** ("missing or empty"), so QA's
   present-and-empty `POSTGRES_SERVER` was never the safe hedge its comment claimed.

## Still open

| Item | Owner |
|---|---|
| **Is data actually flowing?** 8 files applied ≠ rows. QA's Kafka SA may read topics but not join a consumer group ([[rw-kafka-sa-lacks-group-binding]]) | verify in `rw_catalog` |
| `promote-to-qa` still watches **etl-pipeline** and will revert #119. DISABLED — must be repointed before re-enabling | Doke |
| Mongo sink (stage 1b): needs a QA Atlas DB/user + `op-usxpress-qa/risingwave/mongodb` | Doke |
| Employee (stage 2): `entities` DB, `rw_entity_app`, schema, publication, `wal_level`, + `risingwave/entity` secret | Doke |
| `values-qa.yaml` line ~47 still claims apply.sh validates every value before EXCLUDE_RE — false, and load-bearing | tidy-up |
| Prod: untouched. Same list again, nothing pre-existing | after QA |

---

## ✅ DATA VERIFIED AT THE DESTINATION — 2026-10-14 18:19Z

| Object | rows |
|---|---|
| `activeresource` (table) | **1467** |
| `brand_mv_raw` / `brand_mv_flat` / `brand_mv_state` | 0 |

**ActiveResource is genuinely ingesting on QA** — 1467 rows within minutes of the 18:13 apply.
That kills "QA's Kafka SA cannot join a consumer group" as a blanket explanation: the same
credential set works.

**Brand is empty because the QA TOPIC is empty**, proven from the compute log:

```
fetch kafka watermarks: low: 194, high: 194,
  split: KafkaSplit { topic: "qa_brand_management_cdc_brand_avro", partition: 0,
                      start_offset: Some(193) }
backfill_info: {"0": NoDataToBackfill}
```

low == high ⇒ **zero retained messages**. RisingWave read the watermarks, which requires working
auth, and found nothing. No errors in the log. **Not a delivery, credential, schema or
authorisation fault** — nothing is producing to that QA topic, or retention expired the 194
messages it once held. Owner: whoever runs the Brand CDC producer for QA.

⚠️ `rw_kafka_job_lag` returns **0 rows even for a source that is demonstrably consuming**
(ActiveResource). It is not a usable "is it reading?" signal. The compute log's
`fetch kafka watermarks` + `backfill_info` lines are, and they distinguish *empty topic* from
*cannot read* — which no status field does.

## Verdict

- **Delivery chain: WORKING on dev and QA.** Same digest, same repository, same tree.
- **dev**: runs everything; exercised by Tim's real push today.
- **QA**: runs Brand (source/ingest/transform) + ActiveResource. ActiveResource has data.
  Brand will populate the moment its topic does — no further work needed on our side.
- Still excluded on QA by design: Mongo sink, Employee, Brand prescript.

---

# Addendum 2026-10-15 — the promotion chain already exists

## What I was about to build, and should not

Yesterday's plan said "repoint `promote-to-qa.yml` to copy dev's digest". **Wrong target.**
`promote-to-qa.yml` is a *superseded predecessor*. `promote.yml` (workflow id `380029115`,
**active**) already implements the whole chain, and its own header states it:

```
dev  <- the newest digest in the app's ECR repository
qa   <- the digest values-dev.yaml is already running
prod <- the digest values-qa.yaml is already running
...PROD DOES NOT self-merge. It opens a PR and waits for a person, deliberately.
```

So "whatever reaches prod went through QA on the same digest, and a human merges prod" is
**already structural**, not a convention. Nothing needed writing.

## Why QA is not promoting: one word in `apps.json`

`apps.json` (repo root, `variant-inc/risingwave-pipeline`):

```json
"ecr": "risingwave/poc-pipeline",
"promote": ["dev"],
"values": { "dev": "...values-dev.yaml", "qa": "...values-qa.yaml", "prod": "...values-prod.yaml" }
```

`promote` is the **opt-in list**. QA is absent, so every tick logs
`risingwave-etl/qa: not in the promote list, skipping`. Turning QA on is adding `"qa"`.

⚠️ **Corrects an inference from yesterday.** dev and QA sharing `sha256:4553550446f9` is the
result of **my PRs #118/#119**, not of the workflow. The workflow has never promoted QA.

## PR #119 was a prerequisite, not just a bug fix

`promote.yml` hard-fails before touching anything:

```bash
if ! grep -qE "repository:[[:space:]]*.*/${ECR}\$" "$VF"; then
  echo "::error::$KEY/$TARGET: $VF does not point at $ECR"; exit 1
fi
```

Before #119, `values-qa.yaml` pointed at `etl-pipeline`. Adding `"qa"` to the list then would
have **errored loudly** rather than shipping a digest that cannot be pulled — the gate-5 trap
from [[delivery-is-a-relay-of-nine-gates]], already guarded here. #119 is what makes QA
eligible. Its `sed` is also anchored to `^[[:space:]]*digest:`, so it cannot hit another
`sha256:` in the file.

## `promote-to-qa.yml` is an armed trap — confirmed, with the mechanism

- `cron: '*/10 * * * *'` ⇒ re-enabling it fires **within ten minutes**, no human involved.
- `ECR_REPOSITORY: risingwave/etl-pipeline` ⇒ it polls the **wrong registry** and seds that
  digest into `values-qa.yaml`, which now reads `poc-pipeline`.
- It has **no repository guard** (that check exists only in `promote.yml`).

Net effect of re-enabling: an `etl-pipeline` digest written into a `poc-pipeline` reference —
a digest that *cannot exist* in the repository QA pulls from. Straight to `ImagePullBackOff`.
It also writes `deploy/overlays/qa/image-digest.yaml`, a retired path.

→ **Delete it.** Deleting is correct; repointing it would duplicate `promote.yml`.

## Prod must stay out of the list for now

`values-prod.yaml` **does not exist on master** (it is in open PR #84). `promote.yml` handles
that gracefully — `::warning:: values file missing` and continue — so adding `"prod"` early is
harmless but inert.

⚠️ **Soak time is zero by construction.** `matrix: [dev, qa, prod]` with `max-parallel: 1`
means one 10-minute tick can carry an image ECR → dev → QA → *prod PR opened*. Each job
re-checks out `master` after the previous one merged, so prod would read a QA digest that is
seconds old. Prod still needs a human merge, so **the human is the only soak gate.** If real
dwell time in QA is wanted, that is a new requirement — it is not in there today.

## `deploy/overlays/qa/CUTOVER_SCOPE.md` is stale and actively misleading

It documents the retired overlay path (`PIPELINE_DIR=/pipeline/pipelines`, `APPLIED_BY=argocd-qa`)
and publishes this `EXCLUDE_RE`:

```
(^|/)(Template|employee|secret_manager|shared)(/|$)|^pipelines/Brand/(300-transform\.sql|400-sink\.rw)$
```

Every path in it is wrong against the real tree: `employee` is `300-Employee`, `Brand/` is
`100-Brand/`. **This is very likely the origin of the regex-that-matched-nothing**
([[validator-checks-every-value-not-the-selected-ones]]) — a document that reads as
authoritative and matches no file. Mark it superseded in the same PR as the deletion.

## What is proven

- `promote.yml` is active, implements ECR→dev→QA→prod on one digest, and gates prod on a human.
- QA is off solely because `apps.json` lists `["dev"]`.
- `promote.yml` carries the repository guard; `promote-to-qa.yml` does not.
- `values-prod.yaml` is absent from master.

## Tested and killed

- "Repoint `promote-to-qa` to copy dev's digest" — killed: `promote.yml` already does it.
- "Yesterday's equal digests prove the promotion workflow works" — killed: QA has never been
  in the promote list.

## Traps

1. A disabled workflow with a `*/10` cron is not dormant, it is armed.
2. Two workflows, one superseded, both plausible from the name — read `gh workflow list --all`
   and the *active* one first. Same shape as [[edited-copy-is-not-the-shipped-copy]].
3. `gh pr view --json mergeable` returns `UNKNOWN` on first ask; GitHub computes it lazily.
4. A scope document can be the *source* of a bug, not a record of it.

## PRs raised 2026-10-15

| PR | Change | State |
|---|---|---|
| **#121** | Delete `promote-to-qa.yml`; mark `overlays/qa/CUTOVER_SCOPE.md` superseded | open |
| **#122** | `apps.json` gains `"qa"`; gate limits automatic triggers to dev | open |

**Decision (Doke, 2026-10-15):** QA and prod promote on **explicit dispatch only**. A
scheduled or `workflow_run` tick promotes dev and nothing else. This is his original wording —
*"only on Push to QA and on Push to Prod not before"* — made structural.

The gate condition, tested across all 17 trigger/environment combinations, 0 mismatches:

```sh
if [ "$ONLY" != "$E" ] && { [ -n "$ONLY" ] || [ "$E" != "dev" ]; }; then  # skip
```

`$ONLY` is `inputs.only`, empty on every automatic trigger, so only `dev` can pass.
Side effect worth keeping: a scheduled run can no longer reach prod at all, which removes the
ECR→dev→QA→prod-PR-in-one-tick path where QA held the digest for seconds.

Promotion command once merged:

```
gh workflow run promote.yml --repo variant-inc/risingwave-pipeline -f only=qa
```

### Live confirmation before the change (run 38741502511, 13:18Z)

A dispatch with `only=qa` on unchanged master returned, in the workflow's own words:

```
risingwave-etl/qa: not in the promote list, skipping
No promotion for qa.
```

All three matrix jobs reported `success` while only QA was gated in — dev and prod skipped on
`only=qa`. **Proves the promote list was the only thing holding QA**, and that a green run here
says the check ran, not that anything deployed.

⚠️ **Handover note, corrected.** I concluded mid-session that the WSL paste was corrupting,
from echo showing `fi )--title ...` with the continuation line reordered. Wrong: the bytes
arrive intact and the commands ran: it is the terminal's echo of a multi-line paste
interleaving with command output. Do not redesign a block around display scrambling. The real
failure earlier was simpler — a block was skipped, and its own guard caught it
([[transport-failure-not-a-verdict]] in reverse: I read a display artefact as a finding).

---

# Addendum 2026-10-15 (2) — what promotion does NOT carry

**Doke's question:** dev's first push hit DB, Kafka and Mongo-sink problems; those were fixed
"and made IaC" — do they auto-resolve when a push reaches QA?

**No, and the premise does not hold.** Two separate reasons.

## 1. Promotion moves one line

`promote.yml` seds the `digest:` line in the target's values file. That is all it does. Four
layers, only the first travels:

| Layer | dev → QA automatic? |
|---|---|
| Image digest | **yes** |
| Chart config (`values-qa.yaml`: env vars, `EXCLUDE_RE`, ExternalSecret entries) | no — separate per-env file, written by hand (PRs #117/#119/#120) |
| AWS Secrets Manager values | no — different AWS account per environment |
| The external systems (Atlas DB+user, Kafka topic+ACL, `entities` DB/role/publication) | no — outside the repo entirely |

QA runs dev's exact code against **QA's own infrastructure**. A missing database or topic does
not fail the promotion; the file is simply excluded or the Job errors.

## 2. The dev fixes were never put in Terraform

`iaac-risingwave-onprem/deploy/terraform/secrets.tf` on `main` declares exactly **five**
secrets: `postgres`, `root`, `svc-reporting`, `secret_store_private_key`,
`console_license_key`. **`entity`, `mongodb` and `kafka` are absent.** They were created by
hand on dev. So there is no Terraform to run for QA — confirms the 2026-10-09 note rather than
superseding it.

Leverage: the file uses `${local.sm_prefix}`, so it is environment-generic. One PR adding the
three (following the `console_license_key` pattern — secret + `ignore_changes`, value set out
of band) covers dev, QA **and** prod.

⚠️ **Trap on that PR.** Dev's three already exist live and are not in state. A naive apply
either fails as already-existing or rotates a live third-party credential. Both the secret and
its *version* need importing — but `import` blocks in this very file are what broke prod's
first plan ([[terraform-import-blocks-block-new-envs]]), so it must be state-level import per
environment, not blocks in the source.

## Measured on op-qa 2026-10-15, `app-risingwave`

`etl-pipeline-credentials`: `SecretSynced True`, synced 16m. AWS paths it expects:

```
op-usxpress-qa/risingwave/kafka
op-usxpress-qa/risingwave/postgres
op-usxpress-qa/risingwave/root
```

Ten keys landed, **none EMPTY** (`GROUP_ID_PREFIX`, `KAFKA_BOOTSTRAP_SERVER`,
`KAFKA_SASL_USERNAME/PASSWORD`, `KAFKA_SCHEMA_REGISTRY_SERVER/USERNAME/PASSWORD`, `PG_USER`,
`PG_PASSWORD`, `RW_PASSWORD`). Checked for emptiness, not just for `Ready`
([[eso-secretsynced-not-content-check]], [[eso-writes-partial-secrets]]).

**So QA gaps 2 and 3 are each TWO pieces of work, not one** — the chart does not reference
those paths at all yet:

1. a `values-qa.yaml` PR adding the ExternalSecret entries (as PR #117 did for Kafka), **and**
2. the AWS secret + its value + the actual system behind it.

⚠️ **Order matters.** `apply.sh` rejects a **missing OR empty** value, so the `EXCLUDE_RE`
entry must come off **last** — after the system exists, the secret exists, and the key is
non-empty. Un-excluding first fails the whole sync-hook Job, not just that file.

## ⚠️ `op-qa-platform-admin` still cannot list secrets

```
User: .../AWSReservedSSO_op-qa-platform-admin_.../doke@usxpress.com is not authorized
to perform: secretsmanager:ListSecrets
```

[[platform-admin-cannot-write-its-own-secrets]] records op-qa as fixed 2026-08-25. **That fix
was partial** — `ListSecrets` is not in it. Dev and prod were already open; QA is incomplete.
This was a transport failure, not a finding about QA's secrets
([[transport-failure-not-a-verdict]]) — the in-cluster ExternalSecret was the working
instrument, and it uses the ESO role rather than a human identity.

---

# Addendum 2026-10-15 (3) — the IaC for a first-apply-clean environment

**PR #55** on `variant-inc/iaac-risingwave-onprem` — new file
`deploy/terraform/secrets-app.tf`, 233 lines, `terraform validate` → *Success!*

## The gap it closes

`secrets.tf` declared 5 platform secrets. Live dev reads **10** under
`op-usxpress-dev/risingwave/`. The five never declared anywhere:

| Secret | JSON shape (READ from dev's ExternalSecrets, not inferred) | Pattern |
|---|---|---|
| `entity` | `{"username","password"}` → `POSTGRES_ENTITY_USER/_PASSWORD`, username = `rw_entity_app` | `random_password` — automatic |
| `grafana` | `{"username","password"}` → `admin-user`/`admin-password` | `random_password` — automatic |
| `kafka` | 7 × `kafka__*` → `KAFKA_*` / `GROUP_ID_PREFIX` | placeholder |
| `mongodb` | `{"MONGODB_CONNECTION_STRING"}` | placeholder |
| `dex_entra_client_secret` | `{"DEX_ENTRA_CLIENT_SECRET"}` | placeholder |

⚠️ **kafka's JSON keys do not match the env-var names they map to**
(`kafka__api_key` → `KAFKA_SASL_USERNAME`, `kafka__schema_registry_api_key` →
`KAFKA_SCHEMA_REGISTRY_USERNAME`). An identity mapping would have produced seven dead keys
with every status field green. Read the consumer's `remoteRef.property`, never guess.

## The design, and why each half is needed

- **First apply in a new environment works**: `random_password` for the two we own; a
  self-describing sentinel for the three third-party ones. A third-party credential cannot be
  invented, so the achievable goal is a *named* placeholder rather than an empty value.
- **No future apply breaks anything**: `ignore_changes = [secret_string]` on all five
  versions, so a live credential can never be rotated by an apply.
- **`manage_app_secrets` defaults to FALSE.** All five exist in the dev account outside state;
  declaring them unconditionally fails dev's next apply with `ResourceExistsException` on all
  five. CLAUDE.md rule 10 — new behaviour off by default, enabled per environment by a flag.
- **Imports are STATE operations, never `import` blocks.** A bare import block fails the FIRST
  plan of an environment where the resource is absent — five were already deleted from
  `secrets.tf` for that reason ([[terraform-import-blocks-block-new-envs]]). Confirmed today:
  none remain. Do not reintroduce them.

Per environment: merge (no-op) → import what exists → set the flag. A genuinely new
environment skips the import.

Merging is safe in a repo where a merge to `main` is a deploy to every cluster, because this
file is under `deploy/terraform/` — packaged by Octopus, not applied by Flux — and the flag
makes it inert either way ([[risingwave-onprem-has-no-promotion-gate]]).

## Still open, deliberately

1. `grafana_admin_user` defaults to `"admin"`, **unread** from dev. Affects new environments
   only; dev and QA keep their own value via import + `ignore_changes`.
2. `apply.sh` does **not** reject `UNVERIFIED_` today — it rejects missing or empty only.
   Teaching the validator to refuse the prefix is a one-line follow-up and is the point of it.
   ⚠️ I claimed twice in conversation that it already did. It does not.
3. Adopting the `mongodbatlas` provider would make `mongodb` derivable instead of a
   placeholder — the only route to a truly first-apply-clean Atlas. Needs Atlas API keys in
   Octopus; raised separately, not in #55.
4. `terraform fmt -check` exits 3 on this repo because of **pre-existing** drift in
   `variables.tf`. `secrets-app.tf` is fmt-clean. Not folded into #55 — rule 7.
5. No `terraform validate` in this repo's CI. Worth adding; it caught nothing here only
   because it was run by hand.

## Traps from the handover itself

- A gzip+base64 transfer arrived at **exactly** the right byte count with the **wrong** hash —
  a character substitution, not a loss. Per-chunk hashes localised it to chunk 1 of 5 in one
  round trip, so 1000 characters were resent instead of 5000. **Length is not integrity**;
  gate a payload on a hash, and chunk it so a resend is cheap.
- `terraform fmt -check` exit 3 named a file I never touched. An exit code is about the run,
  not about the change — read *which* file it printed ([[a-guard-can-measure-the-wrong-thing]]).

---

# Addendum 2026-10-15 (4) — QA staged, and the last manual step removed

## PRs today

| PR | Repo | State |
|---|---|---|
| #121, #122 | risingwave-pipeline | merged — QA/prod promote on explicit dispatch only |
| #55 | iaac-risingwave-onprem | merged — five app secrets declared, flag off |
| #56 | iaac-risingwave-onprem | merged — module now describes the live dev estate |
| **#57** | iaac-risingwave-onprem | **open** — third-party values from Octopus |
| #97 | risingwave-pipeline | open, **CONFLICTING** — needs a rebase, not a decision |
| #115 | risingwave-pipeline | open, contradicts the direction below — close it |

## QA's secrets now exist

Created by hand, deliberately, as pre-staging for the Terraform adoption:

- `op-usxpress-qa/risingwave/mongodb` — **copied** from dev, because dev and QA share ONE
  non-prod Atlas user (`np_risingwave_service@mongodb.bjpgt.mongodb.net`) and the URI names no
  database.
- `op-usxpress-qa/risingwave/entity` — **generated**, 32 chars, because this is a
  per-environment Postgres role that does not exist yet. Username `rw_entity_app`, matching dev.

QA now holds all five: postgres, root, kafka, mongodb, entity.

⚠️ **Order rule, and it would have broken QA.** ESO writes a **partial** secret when a key
cannot resolve — `SecretSyncedError` while still writing what it could, and the pod then dies
at container creation with `RESTARTS 0` ([[eso-writes-partial-secrets]]). So the AWS secret
must exist **before** the `values-qa.yaml` ExternalSecret entry, never the reverse.

## The design decision: third-party values come from Octopus (PR #57)

Doke's call, and it is the right one. `deploy.ps1` already exports every Octopus variable
named `TF_*` as an environment variable — *"so Terraform picks up TF_VAR_* automatically"* —
so three **sensitive** Octopus variables reach Terraform with **no script change**:

```
TF_VAR_kafka_values     TF_VAR_mongodb_values     TF_VAR_dex_values
```

One `map(string)` per secret, not one variable per key, so adding a key later is a data change
in Octopus rather than code here. `secret_string = jsonencode(merge(local.X_defaults,
var.X_values))`.

**Why it is safe:** absent the variables, `merge()` leaves the `UNVERIFIED_` sentinels and
nothing changes. Supplied, the **first** apply writes the real credential, and
`ignore_changes = [secret_string]` stops every later apply touching it. **It can only ever act
once per environment.**

Net effect on prod: set three Octopus variables, flip the flag, and the first apply creates all
ten secrets with real values. No `aws secretsmanager create-secret` by hand, ever again.

## Two things reading dev corrected

- **`mongodb` carries THREE keys** — `MONGODB_CONNECTION_STRING`, `_USERNAME`, `_PASSWORD` —
  while the module declared one. The ETL consumes only the connection string, but a new
  environment would have come up missing two. Fixed in #57.
- **grafana admin username is `admin`**, so `secrets-app.tf`'s default was right. Verified
  rather than assumed.

## Config ownership: values-<env>.yaml, not the image

Baking `pipelines/config/<env>.env` into the image means one digest behaves differently per
environment, which contradicts the same-digest promotion chain. `apply.sh` already gives the
ConfigMap **precedence** (`if [ -z "${!_key:-}" ]`), so `values-<env>.yaml` wins today and the
`.env` is only a fallback. Direction: move the keys into the values files and drop
`pipelines/config/`. **PR #115 does the opposite and should be closed.**

## Traps

1. A fenced code block of **any** language gets pasted into the shell, not just ```bash. Indent
   non-runnable code instead.
2. A long block genuinely truncates — and the tell is the **shell** reporting `syntax error`,
   not the echo looking scrambled. In one truncation the `K=` assignment was lost and
   `kubectl config view` fell through to the DEFAULT kubeconfig, reporting **qa-one EKS** while
   claiming to measure op-dev. Only the following syntax error stopped it.
3. Both generator scripts push on every run, so a re-paste always produces a non-fast-forward
   rejection. Harmless, but add an "already pushed" check.

## 2026-10-15 close — QA staged and VERIFIED

PR #123 merged. Live on op-qa at 21:41:01Z:

- `etl-pipeline-credentials`: `SecretSynced True`, **13 keys, none empty** — including the
  three new ones (`MONGODB_CONNECTION_STRING`, `POSTGRES_ENTITY_USER`, `_PASSWORD`).
- `risingwave-etl`: `Synced Succeeded`.

Checked for **emptiness**, not just `Ready` — an empty value behind a green ExternalSecret
kills the next hook pod at container creation with `RESTARTS 0`, which no restart alert sees.

**The question this answers:** *can Tim promote dev → QA without breaking it?* Yes.

| What he does | QA |
|---|---|
| Edits an applied file | **Re-applies.** Before #123, `apply.sh` line 191 `exit 1`'d and failed the whole Job. This was the real breakage |
| Adds a file under an excluded path | ignored |
| Adds a file under `100-Brand/` or `200-ActiveResource/` | applied; if it needs a value QA lacks, the Job fails **before applying anything** |
| Changes nothing | `already on <digest>, nothing to promote` |

The third row is the only remaining way QA goes red. **Deliberately not fixed with an
allowlist** — I proposed one and withdrew it. An allowlist means a new file is *silently
ignored*, a green sync over code nobody is running, which is the failure family that has cost
this system the most. Loud red beats silent skip.

Not re-verified, but reasoned from the validator's own behaviour: the eight applied files
should have been **skipped, not re-applied**, because none of them references the new
variables, so their rendered content and hashes are unchanged. Any file referencing
`POSTGRES_*` is excluded — which the 2026-10-14 error proves, since those values were only
demanded when 15 files were selected rather than 8.

⚠️ **Guard that measured the wrong thing (again).** The verification block checked
`kubectl config view` for the right server and called it a session check. That only reads the
file. On-prem kubeconfigs shell out to `aws-iam-authenticator`, so a correct address proves
nothing about auth — the block then produced four walls of credential errors that could have
read as a cluster fault. A liveness guard must make a real API call:
`kubectl get ns default -o name >/dev/null 2>&1 || echo "NOT MEASURED"`.

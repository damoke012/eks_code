# Plan — prove the app delivery path end to end with the real ETL on op-usxpress-qa

**Goal.** One commit to `variant-inc/risingwave-pipeline` → image built and pushed to ECR by
digest → promotion PR merged → Argo CD deploys → the ETL exists in QA's RisingWave catalog.

**Scope allowance from Doke, 2026-08-26:** QA may point at **dev's** Kafka and MongoDB for
this test. Endpoints get corrected to QA's own afterwards. Everything that *needs* an
abstraction layer gets one **before** the test — the allowance is about which values we
supply, not about hardcoding them.

**Untouched throughout:** the `risingwave` namespace on op-qa (13 pods, the platform). This
plan only touches `app-risingwave`, the Argo CD Application, and the pipeline repo.

---

# Phase 0 — resolve four unknowns (blocking, cheap)

| # | Question | Why it blocks |
|---|---|---|
| 0.1 | Is there a MongoDB reachable from op-qa, or do we point at dev's? | `Brand/400-sink.rw` sinks to MongoDB. Without a target the pipeline has no terminus. |
| 0.2 | Do `op-usxpress-qa/risingwave/kafka` and `.../mongodb` exist in Secrets Manager? | ESO can only deliver what exists. `secret.yaml` reads these paths per-env; QA's may never have been created. |
| 0.3 | What is the RisingWave licence key's core limit on op-qa? | `employee` needs `CdcTableSchemaMap`, which the licence gates. Decides whether `employee` is in this pass. |
| 0.4 | Which `%VAR%` values are env-specific vs constant? | Decides ConfigMap vs baked-in. Draft answer below in 1.2. |

**Verify 0.2 with:**
```
aws secretsmanager list-secrets --profile op-qa --region us-east-2 \
  --filters Key=name,Values=op-usxpress-qa/risingwave \
  --query 'SecretList[].Name' --output table
```

---

# Phase 1 — abstraction, in the repo, before anything touches a cluster

Six changes. All in `variant-inc/risingwave-pipeline`, all on one feature branch, all
reviewable as a normal MR. **No cluster is touched in this phase.**

### 1.1 Give `apply.sh` a substitution step

Today `apply.sh` pipes files to `psql` verbatim. Add a render step that replaces every
`%NAME%` from the environment, and **fails loudly on any placeholder it cannot fill** —
a silent pass-through is how `topic = '%KAFKA_TOPIC_BRAND%'` reaches RisingWave.

Shape:
```
render() {
  local f="$1" out missing
  out=$(sed -e "s|%KAFKA_TOPIC_BRAND%|${KAFKA_TOPIC_BRAND:-}|g" ... "$f")   # or a loop over env
  missing=$(printf '%s' "$out" | grep -oE '%[A-Z0-9_]+%' | sort -u)
  [ -z "$missing" ] || { echo "UNRESOLVED: $missing in $f"; exit 1; }
  printf '%s' "$out"
}
```
Prefer a generic loop over `env` rather than a fixed sed list — the fixed list in
`secret.yaml` is exactly why three placeholders were missed.

**Acceptance:** `DRY_RUN=true` with a deliberately unset variable exits non-zero and names
the file and the placeholder.

### 1.2 Split the placeholders into two sources

| Kind | Examples | Delivered by |
|---|---|---|
| **Config** (non-secret, per-env) | `KAFKA_TOPIC_BRAND`, `KAFKA_STARTUP_MODE`, `KAFKA_SCHEMA_REGISTRY_MESSAGE`, `MONGODB_DATABASE`, `MONGODB_COLLECTION` | the overlay's `etl-pipeline-endpoints` ConfigMap |
| **Secret** | `KAFKA_API_KEY`, `KAFKA_API_SECRET`, `KAFKA_SCHEMA_REGISTRY_API_*`, `MONGODB_*` credentials | `etl-pipeline-credentials` via ExternalSecret |

Nothing env-specific stays in the image. This is the abstraction Doke asked for, and it is
what makes "point at QA's own Kafka later" a ConfigMap edit rather than a rebuild.

### 1.3 Extend the ExternalSecret to carry the connector credentials

`deploy/base/externalsecret.yaml` currently has three entries (`RW_PASSWORD`, `PG_PASSWORD`,
`PG_USER`). Add the Kafka and MongoDB values from `op-usxpress-<env>/risingwave/kafka` and
`.../mongodb`, so `shared/000-secrets.rw` can create the RisingWave `SECRET` objects with
real values under Argo CD — no GitHub Action in the path.

⚠️ Patch indices are positional. Adding entries shifts them; **both** overlays' `patches:`
blocks must be updated together. Prod is already missing `/spec/data/2` — fix that here.

### 1.4 Make `shared/` apply before everything else

`apply.sh` sorts full paths, so `Brand` currently runs before `shared/000-secrets.rw` — the
inverse of the stated dependency. Rename:

```
pipelines/shared/  ->  pipelines/000-shared/
```

Digits sort before letters, so it lands first with no code change. Update the three READMEs
that reference the old path.

### 1.5 Fix the `.rw` / `.sql` routing

`apply.sh` sends `*.rw` to RisingWave:4567 and `*.sql` to Postgres:5432. These are Postgres:

```
000-shared/000-audit-setup.rw       14 PL/pgSQL construct lines  ->  .sql
000-shared/002-audit-triggers.rw    40 PL/pgSQL construct lines  ->  .sql
```

Rename to `.sql`. RisingWave has no triggers, no `$$` bodies, no `DECLARE`.

### 1.6 Correct `DATABASE materialize`

`000-shared/001-manager-user-access.rw:143-145` grants against a database called
`materialize` — a different product. RisingWave's database here is `dev`.

### 1.7 (Same MR) Fix the guardrail in `pipeline.yaml`

Not required for the Argo CD path, but this MR will trip it. It blocks
`DROP MATERIALIZED VIEW` — the safe, normal way to iterate RisingWave DDL, present in
`Brand/200-ingest.rw` — while allowing `DROP SOURCE|SINK|SECRET|USER|ROLE`. Add the missing
verbs; allow `DROP … IF EXISTS` of MVs and tables, which is what recreate-idempotently means.

**Phase 1 exit:** MR open, CI green, `DRY_RUN=true` locally resolves every placeholder for
the QA value set. **Nothing deployed yet.**

---

# Phase 2 — reset QA to platform-only

Everything here is op-qa. Nothing prod. Run each and read the output before the next.

### 2.1 Record what exists, so the reset is reversible
```
bash ~/eks_code/scripts/rw-etl-inventory.sh | tee ~/qa-before-reset.txt
bash ~/eks_code/scripts/onprem-kubectl.sh op-qa -- -n app-risingwave get all,externalsecret,cm,secret
bash ~/eks_code/scripts/onprem-kubectl.sh op-qa -- -n argocd get applications,applicationsets -o yaml > ~/qa-argocd-before.yaml
```

### 2.2 Stop Argo CD re-creating what we delete
Remove `risingwave-etl` from the ApplicationSet generator, or set the Application's sync
policy to manual **first**. Deleting resources under an active ApplicationSet just makes it
put them back.

### 2.3 Delete the app-side objects — NOT the platform
```
-n app-risingwave delete job    etl-pipeline-apply --ignore-not-found
-n app-risingwave delete externalsecret etl-pipeline-credentials --ignore-not-found
-n app-risingwave delete cm     etl-pipeline-endpoints --ignore-not-found
```
Leave the namespace, the quota, the PSA labels and `ecr-pull-secret` — platform-owned.

### 2.4 Clear the tracking table
The applier skips any file whose hash it has seen. The smoke row must go or nothing re-runs:
```
DELETE FROM pipeline_applied;     -- db `risingwave`, user `risingwave`, on pg-postgresql-0
```
Keep the table; `apply.sh` creates it `IF NOT EXISTS` anyway.

### 2.5 Confirm the RisingWave catalog is empty
It already reads 0 sources / 0 MVs / 0 sinks / 0 secrets (2026-08-26). If that changed,
drop in reverse dependency order — sinks, then MVs, then sources, then secrets.

**Phase 2 exit:** `rw-etl-inventory.sh` shows QA platform healthy, catalog empty,
`app-risingwave` holding only platform-owned objects, `pipeline_applied` empty.

---

# Phase 3 — supply QA's configuration

### 3.1 Populate Secrets Manager (whatever 0.2 showed missing)
`op-usxpress-qa/risingwave/kafka` and `.../mongodb`. For this test these carry **dev's**
values, deliberately.

### 3.2 Set the QA overlay's ConfigMap
`deploy/overlays/qa/endpoints.yaml`:
```
PIPELINE_DIR: /pipeline/pipelines        # was /pipeline/smoke  <- THE switch
KAFKA_TOPIC_BRAND: dev_brand_management_cdc_brand_avro
KAFKA_STARTUP_MODE: earliest
KAFKA_SCHEMA_REGISTRY_MESSAGE: <from dev's live source definition>
MONGODB_DATABASE / MONGODB_COLLECTION: <per 0.1>
```
Leave `RW_HOST`/`PG_HOST`/`PG_DB: risingwave` alone — those are correct and hard-won.

### 3.3 Confirm ESO delivers real values
A green `SecretSynced` proves the sync ran, not that the value works — this has bitten us
twice. Read the decoded value and check it against Secrets Manager.

---

# Phase 4 — the test itself, as one commit

This is the thing being proven. Each step has an observable.

| Step | Action | Observable |
|---|---|---|
| 4.1 | Merge the Phase 1 MR to `master` | `gh run list` — `build-and-push` starts |
| 4.2 | `build-and-push` builds and pushes by digest | run summary prints `…/risingwave/etl-pipeline@sha256:…`; tag `${{ github.sha }}` is immutable |
| 4.3 | `promote-to-qa` opens the promotion PR | new `promote/qa-<sha>` branch and PR; diff is one digest line |
| 4.4 | **Review the promotion PR diff in full** | only `deploy/overlays/qa/kustomization.yaml`, only the digest. Rule 7 — read the lines you did not mean to change |
| 4.5 | Merge the promotion PR | Argo CD `risingwave-etl` revision moves to the new commit |
| 4.6 | Argo CD syncs; the sync-hook Job runs | Job logs in the Argo UI: `apply pipelines/000-shared/000-secrets.rw`, then Brand's four files |
| 4.7 | Job completes | `hook-delete-policy` now retains failed Jobs (#15), so a failure leaves its logs |

⚠️ **`pipeline.yaml` fires on the same push** (both trigger on `pipelines/**`). It will queue
an ARC-runner job against dev's `risingwave-2` and pause at its approval gate. Decide before
4.1 whether to approve it, cancel it, or disable that trigger for this test.

---

# Phase 5 — verify the claim, not the adjacent one

```
bash ~/eks_code/scripts/rw-etl-inventory.sh
```

**Pass =** op-qa `risingwave` reports the real objects — `kafka_brand`, `mv_brand`,
`mv_brand_state`, the MongoDB sink — and `pipeline_applied` holds a row per applied file with
the new digest and `argocd-qa`.

**Not pass:** Application `Synced/Healthy`, or the Job exiting 0, or an ExternalSecret
`SecretSynced`. Those are the step next to the one that matters.

Then, and only then, is "the delivery path is proven **with a real pipeline**" a true
sentence — as distinct from 2026-08-20, which proved the path with a smoke test.

---

# Sequencing of the pipelines

1. **`000-shared`** — secrets first; everything depends on them.
2. **`Brand`** — the real target. Kafka source, 2 MVs, MongoDB sink.
3. **`secret_manager`** — 2 more sources, same shape as Brand.
4. **`employee`** — LAST, and only if 0.3 clears the licence. Needs Postgres CDC and
   `CdcTableSchemaMap`.
5. **`Template`** — scaffold only. Exclude it from `PIPELINE_DIR` or it creates junk objects;
   it is documentation, not a pipeline.

⚠️ `Template/` currently sits under `pipelines/` and would be applied. Move it out, or teach
`apply.sh` to skip it.

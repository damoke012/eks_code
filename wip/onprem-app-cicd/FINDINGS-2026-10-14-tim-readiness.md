# Is Tim actually ready to use it? — 2026-10-14

Checked against the message sent to Tim 2026-10-13. **Verdict: no.** Three of the four
variable categories in that message are not usable today, and category 1 is further from
done than the message's own "Where this stands today" says.

## ⛔ Category 1 (his .env files) — the mechanism does not exist in code

The message tells Tim: add the line to `pipelines/config/{dev,qa}.env`, PR into master, "the
image rebuilds and the next sync picks it up."

**Nothing reads those files.** All four `apply.sh` copies in wip/ score **0** for
`config/`, `.env`, `ENV_FILE` and `set -a` — including `reapply/apply.sh`, the newest draft
(10-13). Its own header states placeholders are resolved "from the environment: non-secret
values from the overlay's `etl-pipeline-endpoints` ConfigMap, credentials from the
`etl-pipeline-credentials` ExternalSecret." There is no env-file path, merged *or drafted*.

So the message understates it: this is not a pending image rebuild, it is **unwritten code**.
A rebuild alone delivers nothing.

**Consequence if Tim acts on the message today:** apply.sh REFUSES a file whose placeholder
it cannot fill. He adds `FOO` to `dev.env`, uses `%FOO%` in a `.rw`, and his push is rejected.
Loud, not silent — but it is a hard stop, not a working loop.

⚠️ **Design changed and the note was never reconciled.** `tim-env-grouped-2026-10-08.md`
says his non-secret keys "all go in the Helm values file, in the section Tim raises PRs
against" — i.e. PRs against OUR repo. The 10-13 message says his own repo, "No PR against
our repo." Pick one before writing the code.

⚠️ **The immutable-tag trap applies to the rollout**
([[immutable-tag-blocks-base-image-rebuild]]): merging into `risingwave-pipeline` and
republishing `sql-applier` **cannot** reach `risingwave-poc`'s unchanged commit. The rollout
is three parts — merge, republish the base, then an **empty commit + dispatch in Tim's repo**.
Two thirds of it looks complete and delivers nothing.

## ⛔ Category 4 (his secrets path) — off, and has no identity

`app-secret-split/values-dev-addition.yaml` (draft, 10-13): `appSecret.enabled: false` and
**`roleArn: ""`**. Needs the IAM role created from `iam-policy-app-secrets.json`, the ARN
written in, `enabled: true` on dev, a first key in `op-usxpress-dev/risingwave/app`, and the
PR merged. All drafts — nothing proven merged.

The message already tells Tim this one is empty and switched off, so it is consistent; it is
just not "ready to use".

## ⛔ Dev-only re-apply — draft, same image as category 1

`reapply/apply.sh`: `REAPPLY_CHANGED="${REAPPLY_CHANGED:-false}"`, off until a values file
opts in. **Rides the same image rebuild as category 1** — one rebuild covers both, so
sequence them together rather than twice.

## ❓ KAFKA_TOPIC_ACTIVE_RESOURCE

The message says it is temporarily in two places. **Zero occurrences anywhere in wip/** — no
record of which two, or of the move. Unverified; needs a grep across both repos.

## Known, already disclosed

No prod values file. Dev and QA only.

## Proven / killed / traps

- **Proven:** the write path itself works end to end — poc#11 → ECR `sha256:40cc5bfb` →
  promotion PR #92 self-merged → hook Succeeded → 13-key secret (2026-10-09). The relay is
  real; what is missing is only the developer-owned variable layer on top of it.
- **Killed:** "it just needs tomorrow's rebuild." The code does not exist.
- **Trap:** every status field here is green. Judge at the destination — a refused file in
  the hook output, not a synced Application.

---

## ⚠️ CORRECTED 2026-10-14, measured against master (not wip/)

**The two ⛔ verdicts above were wrong, both from reading `wip/` instead of the branch** —
the exact failure CLAUDE.md rule 7 warns about. Master is AHEAD of every draft here.

| Claim above | Measured on master | Verdict |
|---|---|---|
| no env-file code anywhere | `build/apply.sh` has **2** matching lines | UNRESOLVED, not absent |
| `roleArn: ""` | `arn:aws:iam::700736442855:role/op-usxpress-dev-rw-app-secrets` | WRONG — populated |
| `appSecret.enabled: false` | `false` | correct |
| re-apply not opted in on dev | no `REAPPLY` in `values-dev.yaml` | correct |

`env-loading lines: 2` is itself a coarse instrument — `[.]env` matches a comment as happily
as a `source`. Reading the two lines is the only thing that settles category 1.

**`KAFKA_TOPIC_ACTIVE_RESOURCE` duplication CONFIRMED**, exactly as the message told Tim:
`deploy/chart/values-{dev,qa}.yaml` (ours) **and** `pipelines/config/{dev,qa}.env` (his), with
identical values in both. Also in his `200-ActiveResource/110-source-active_resource.rw`,
`README.md`, `TODO.md` and `.env.example`.

**Cluster, op-dev (authenticated):** 30 endpoint keys, 13/13 credential keys,
`etl-pipeline-credentials` SecretSynced 23m ago. `etl-app-credentials` absent and no `rw-app`
SecretStore — consistent with `enabled: false`, not a fault.

**Open PRs:** `risingwave-pipeline` #98 (qa inert config), #97 (bootstrap the application
database as a sync hook), #84 (values-prod + render guard) — all ~4 days old, **none is the
env mechanism**. `risingwave-poc`: none.

---

## RESOLVED on master 2026-10-14 — both changes merged, code verified

| Commit | When | What |
|---|---|---|
| `6a6210d3` | 2026-10-13 22:48:47Z | #102 source per-env config from the pipeline image (Idris) |
| `c705f345` | 2026-10-13 22:53:11Z | #111 allow an environment to re-apply an edited file (Doke) |

Five minutes apart, so the "mine first, then yours" sequencing is moot — any image built
after 22:53 carries both. The exposure window needed someone editing `dev.env` inside those
five minutes.

**All three review points Doke raised are implemented**, read from master:
- **Precedence** — `if [ -z "${!_key:-}" ]; then export "$_line"`. The file only fills what is
  unset, so the ConfigMap and Secret win. `-z` also makes **empty == unset**, which is the
  partial-ESO-secret fix.
- **CRLF** — `_line="${_line%$'\r'}"` strips it on read.
- **prod.env** — dropped.

### ⛔ Still open 1 — dev has NOT opted into re-apply

`REAPPLY_CHANGED="${REAPPLY_CHANGED:-false}"` and a case-insensitive grep of
`values-dev.yaml` finds **no `reapply` key at all**. Merged in code, OFF on dev. The whole
point of #111 — "removes the class of problem Tim keeps hitting" — is not yet in effect.

### ⛔ Still open 2 — is the running image new enough?

`values-dev.yaml` digest == cluster ConfigMap digest ==
`sha256:2357f5a413f21edc82aa746d4dd4b7deb57bbe971ecde2c202b4998338ea39e2`. Consistent, but
**nothing yet proves it was built after 22:53Z**. `apply.sh` ships in `sql-applier`;
`poc-pipeline` builds FROM it, so the new applier only reaches dev via a `poc-pipeline`
rebuild ([[immutable-tag-blocks-base-image-rebuild]]). ECR `imagePushedAt` settles it.

### ⚠️ The silent-skip to watch

`if [ -n "$ENVIRONMENT" ] && [ -f "$_config_file" ]` has **no else branch**. An unset or
mismatched `ENVIRONMENT` skips the whole block with no warning; the `echo "loading pipeline
config:"` line is the only evidence it ran. A `.env`-only variable then has no value and the
file is REFUSED for an unfillable placeholder — which reads as Tim's SQL being wrong.

`app-risingwave` holds **no Jobs and no pods** between syncs (the applier is a sync hook Argo
deletes either way), so the durable record is `.status.operationState.syncResult`.

---

## ⛔ MEASURED — dev's image predates #111. Neither change is confirmed live.

| Event | UTC |
|---|---|
| #102 env sourcing merged (`6a6210d3`) | 2026-10-13 22:48:47 |
| poc build #16 "per-environment pipeline config files" → `2357f5a4` | ~22:49 (43s run) |
| **promote #109 writes `2357f5a4` into `values-dev.yaml`** | **22:50:11** |
| #111 re-apply merged (`c705f345`) | **22:53:11** |

**Dev's running image was promoted 3 minutes before #111 was merged, so it cannot contain it.**
No `values-dev.yaml` digest commit exists after 22:50:11Z and the newest `poc-pipeline` build
is still #16 — nothing newer has been built, so the 10-minute `promote` schedule has had
nothing to do all night. Every signal is green and nothing has moved.

#102 is **unresolved**: it merged 84 seconds before the poc build started. Whether it is in
`2357f5a4` depends on whether `apply.sh` arrives via a `FROM sql-applier` base (then it needed
a `sql-applier` rebuild + push inside 84s — effectively impossible) or is copied at poc build
time (then it is in).

**Fix is the immutable-tag rollout** ([[immutable-tag-blocks-base-image-rebuild]]):
`poc-pipeline` tags by commit SHA, so re-dispatching `master` fails at push. Needs a NEW commit
in `risingwave-poc` — and if `build-sql-image` carries a `paths:` filter, an empty commit
creates **no run at all**, indistinguishable from a build that has not started. Check for a run
against the new SHA before concluding anything.

Setting `REAPPLY_CHANGED` on dev before the new image lands is **inert** — the running applier
has no code that reads it.

### Trap recorded
Five separate digests were promoted to dev between 20:09 and 22:50 on 10-13. Dev's image moves
with no human decision. Acceptable on dev; needs a gate before that pattern reaches prod.

---

## 🔑 THE TRAP — the applier is pinned by digest in TIM's workflow

`usxpressinc/risingwave-poc/.github/workflows/build-sql-image.yml` line 34:

    applier_image: 064859874041.dkr.ecr.us-east-2.amazonaws.com/risingwave/sql-applier@sha256:0a13bc0de62116d208d6281a5df5647ff57e34a9cd56b84f15dfce7ce43fb8d3

**Rebuilding `poc-pipeline` cannot deliver a new `apply.sh`.** An empty commit, a dispatch, a
`paths:`-matching change — all produce a new `poc-pipeline` digest built from the *same old
applier*, which then promotes to dev perfectly green with neither #102 nor #111 in it.

This invalidates the "empty commit in the consuming repo" rollout from
[[immutable-tag-blocks-base-image-rebuild]] **for this repo pair**: that memory assumes the
base is referenced by a moving tag. Here it is a pinned digest, so the rollout gains a step —
**bump the pin** — and the usual trick silently does nothing. Generalise: before concluding a
rebuild will pick up a base-image change, read how the base is REFERENCED.

Dev's build started 2026-10-13T22:48:56Z, nine seconds after #102 merged — irrelevant because
of the pin.

### Correct rollout
1. Build `sql-applier` from pipeline `master` (holds #102 + #111); capture the digest.
2. Bump `applier_image` in Tim's `build-sql-image.yml` (Doke has `push: true` on that repo).
3. That commit builds `poc-pipeline` on the new applier.
4. Promote to dev (dispatch, don't wait for the `*/10`).
5. Re-apply flag + verify both strings.

### ⛔ Also — nothing passes REAPPLY_CHANGED
`deploy/chart/templates/job.yaml` has **no `REAPPLY` entry**, only `ENVIRONMENT` (line 70,
`value: {{ include "etl.env" . | quote }}`). #111 added the flag to `apply.sh` but no chart
wiring, so it must ride the `config:` map into `etl-pipeline-endpoints` and arrive via
`envFrom`. Verify `etl.env` renders exactly `dev`, or the config file is skipped silently.

---

## 🔴 ROOT CAUSE — #102 and #111 landed in a copy of apply.sh that nothing builds

`sql-applier` is built by **`variant-inc/iaac-risingwave-cicd`** → `.github/workflows/publish-applier.yml`
from **that repo's** `build/Dockerfile` + `build/apply.sh`.

`variant-inc/risingwave-pipeline/build/apply.sh` — where both PRs landed — **is not in any
image build path.**

| copy | bytes | has `_config_file` / `REAPPLY` / `ENVIRONMENT` | last touched |
|---|---|---|---|
| `risingwave-pipeline/build/apply.sh` | 9342 | yes (#102, #111) | 2026-10-13 22:53Z |
| **`iaac-risingwave-cicd/build/apply.sh` (SHIPPED)** | **7033** | **none — 0 matches** | 2026-10-09 22:09Z |

The same fix landed separately in both repos five days ago — `risingwave-pipeline#94` 10-09
22:11Z and `iaac-risingwave-cicd#3` 10-09 22:09Z — so the duplication was already being
maintained by hand and nobody noticed the second copy was the live one.

**The digest pin is not the fault — it is what made the fault invisible.** The applier is
correctly frozen by digest, so the image has been honestly reporting 4-day-old behaviour
throughout. Two earlier theories (needs a rebuild; needs a pin bump) were both downstream of
this and both wrong.

⚠️ `values-dev.yaml` sets `EXCLUDE_STRICT: "true"`. If the shipped script has no
`EXCLUDE_STRICT`, that setting is **already inert on dev** — same class, already live. Check in
the diff.

### Correct sequence
1. Port #102 + #111 into `iaac-risingwave-cicd/build/apply.sh` (the files are 2309 bytes apart,
   so diff first — this may not be a clean cherry-pick).
2. Merge to `main`; `publish-applier` fires on push → new `sql-applier` digest.
3. Bump `applier_image` in `usxpressinc/risingwave-poc/.github/workflows/build-sql-image.yml`.
4. That commit rebuilds `poc-pipeline` (its `paths:` includes that workflow file).
5. Promote to dev.
6. `REAPPLY_CHANGED: "true"` under `config:` in `values-dev.yaml` (dev only; `envFrom` carries
   it — `job.yaml` has no explicit entry). `ENVIRONMENT` = `.Values.environment` = `dev`, so
   `config/dev.env` resolves.
7. Verify `loading pipeline config:` + a `REAPPLY` line, then release Idris, then tell Tim.

### Structural fix owed
One of the two `apply.sh` copies must stop existing. Two repos, one script, fixes landing in
each independently — [[a-version-declared-twice-will-drift]] with a container image in between.

### Diff measured — it IS a clean port (225 vs 178 lines)

`risingwave-pipeline/build/apply.sh` is a **strict superset**. Every `<` line (7 of them) is the
old form of a line the new version replaces — old `REFUSED` block, old counters, old summary.
Nothing in the shipped copy is lost by taking the pipeline copy verbatim.

Delta = exactly the two features: `REAPPLY_CHANGED` + `ENVIRONMENT` vars, the config-sourcing
block, `pipeline_applied_history`, the REAPPLY/REFUSED branch, the history insert, the summary.

**Two earlier worries of mine were wrong, both settled by this diff:**
- *"the config block has no else branch, so a bad ENVIRONMENT skips silently"* — **FALSE**. It
  has `elif [ -n "$ENVIRONMENT" ]` logging `no pipeline config at ...`. Correct as written.
- *"EXCLUDE_STRICT may be inert on dev"* — **FALSE**. It appears in neither side of the diff,
  so both copies have it identically.

---

## ✅ DELIVERED AND PROVEN — 2026-10-14 13:44:39Z

| Step | Evidence |
|---|---|
| Port into the SHIPPED applier | `iaac-risingwave-cicd#5` merged |
| New applier published | `sql-applier@sha256:e7dbbb30…` pushed 13:31Z |
| Pin bumped in Tim's workflow | `risingwave-poc#21` merged |
| New pipeline image | `poc-pipeline@sha256:9ca9c590…` pushed 13:38Z |
| Dev opted into re-apply | `risingwave-pipeline#113`; ConfigMap `REAPPLY_CHANGED=true` live |
| Promoted to dev | `#114` 13:41:44Z; `etl-pipeline-image` = `9ca9c590…` |
| Argo synced | `Synced / Succeeded` 13:44:39Z |
| **THE PROOF** | **`pipeline_applied_history` exists in `pg-postgresql`** |

That table is created **only** by the new `apply.sh`. It is the durable proof the skill asks
for — the hook Job is deleted by Argo either way, so its log was never available.

### Build note — the Trivy gate is flaky, not a finding
Push run `38573130027` failed at step 9 **Scan**; `Push by digest` skipped. The identical SHA
passed on `workflow_dispatch` (`38573373054`) minutes later. Same code, same base ⇒ transient.
Because the failed run never pushed, the immutable tag stayed free and the retry succeeded.
A scan that fails transiently trains people to re-run it; worth pinning properly.

### Dev has TWO Postgres services, one pod
`pg-postgresql` (what the applier uses, endpoint `10.244.3.142:5432`) and `postgres-postgresql`
both resolve to `postgres-postgresql-0`. Not a fault, but the pod name does NOT match the
service the config names — and QA's pod is `pg-postgresql-0`, so the name does not travel.

### Still open
1. **Idris** — PR deleting `KAFKA_TOPIC_ACTIVE_RESOURCE` from `values-dev.yaml` + `values-qa.yaml`.
2. **`promote-to-qa` is DISABLED** (`disabled_manually`). Before re-enabling, diff QA's
   ConfigMap keys against `qa.env`: a variable QA's ConfigMap lacks but `qa.env` supplies turns
   a previously-REFUSED file into an APPLIED one — new DDL in QA from a dev change.
3. **Tim** — `appSecret.enabled: false`, no key at `op-usxpress-dev/risingwave/app`. Needs his
   first key. The role ARN is already in place.
4. **Delete `risingwave-pipeline/build/apply.sh`** — nothing builds it; it cost a day.

---

## ✅ EXERCISED BY A REAL PUSH — 2026-10-14 15:31:44Z

Tim merged `risingwave-poc#22` at 15:26Z editing `pipelines/200-ActiveResource/210-ingest-active_resource.rw`
(+2/−0). Build green, promoted, synced. Applier output:

```
loading pipeline config: /pipeline/pipelines/config/dev.env      <- #102 live
  selected 18 of 24 discovered, excluded 6
  REAPPLY  pipelines/200-ActiveResource/210-ingest-active_resource.rw
           recorded 628577745d6d  now 0bf90608adb8                <- #111 live
applied 1, re-applied 1, skipped 17
```

Ledger persisted: that path now holds `0bf90608adb8` at 15:31:44Z;
`pipeline_applied_history` count 1. **Before today this push would have hard-failed the sync.**

### ⚠️ Design cost now visible: a COMMENT rebuilt the DDL
The edit was ` - making a change to  test ci/cd.` inside a block comment. The hash covers the
whole **rendered** file, so a comment-only change re-ran the DDL and rebuilt what the file
defines (source restarts from its startup mode, MV backfills from scratch). Consequences:
- On dev: a rebuild for a cosmetic edit.
- On QA/prod (strict): a `REFUSED` and a **blocked sync** for a comment or a reformat.
Fix if it becomes a nuisance: normalise comments/whitespace out before hashing.

### Ledger holds orphans
`pipelines/Brand/100-sources.rw`, `pipelines/Brand/200-ingest.rw`,
`pipelines/canary/001-promotion-canary.rw` — paths that no longer exist (Brand/ became
100-Brand/). Harmless, but `pipeline_applied` is a history of applies, **not** a picture of
current state. Don't read it as inventory.

### Handover-command defect (mine)
The wait loop `case "$M" in promote*)` matched the **previous** promotion's message and exited
on iteration 1, so it never showed the new commit. A guard must compare against the value it
expects to CHANGE FROM, not a prefix that was already true.

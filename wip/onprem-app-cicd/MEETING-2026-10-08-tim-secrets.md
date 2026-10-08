# Call: RisingWave pipeline deployment and secrets — 2026-10-08

Doke, Tim Preble, Idris Fagbemi. Tim demoed both pipelines (Brand, Employee) working
end-to-end in local Docker — Postgres CDC → RisingWave → Mongo, three Brand rows and one
Employee row confirmed in all three stores. The blocker he named is not the pipelines. It is
**where his environment variables go.**

## What was agreed

| | |
|---|---|
| Tim splits his `.env` into Docker-local / platform / developer | ✅ already sent — classified in `tim-env-classification-2026-10-08.md` |
| Idris writes Tim a script to pull secrets into his local stack | owed, "1–2 hours" |
| Doke wires dev so a push deploys like QA will | in flight |
| Doke sends Tim the proposed split for pushback | **owed — draft is `MESSAGE-tim-env-split-2026-10-08.md`** |

## Corrections — things said on the call that are wrong or incomplete

**1. "Those Kafka keys aren't sensitive, they can be a ConfigMap."** Half right. Topic names,
bootstrap server, security protocol and the registry *endpoint* are config. But
`kafka__api_key`, `kafka__api_secret`, `kafka__schema_registry_api_key` and
`_api_secret` **are** credentials and already live in Secrets Manager. One `.env` section
splits across both destinations.

**2. "The secret is done in GitHub."** No. Secrets live in **AWS Secrets Manager**. GitHub
holds the *trigger* and non-secret coordinates (the `qa` environment carries
`RISINGWAVE_HOST`, `PORT`), and authenticates by OIDC role — no credential values. Putting
values in GitHub secrets would create a second copy that silently drifts.

**3. "Whatever we did in Octopus, just replace it with GitHub."** True for the pipeline repo.
Not true for RisingWave's own Terraform, which still deploys through **Octopus** with the
`TfApply` gate. Both statements are live at once and that will confuse Tim.

**4. "Master is the source of truth; push to master then promote to QA."** True for
`risingwave-pipeline`. **False for `iaac-risingwave-onprem`**, where every cluster tracks
`branch: main` on a 5-minute interval, so a merge there *is* a prod deploy. Two repos, two
branch models.

**5. Tim can "call the External Secrets Operator" from his Docker stack.** He cannot. ESO is a
Kubernetes operator: it reads CRDs and writes Kubernetes Secrets. There is nothing to call
from Docker Compose. The right local path is what Idris landed on — a script that reads
Secrets Manager directly and seeds his local RisingWave with `CREATE SECRET`.

**6. "He needs an AWS access key."** No. He uses **AWS SSO** (`aws sso login`), which is
already the on-prem human access model. No static access key should be minted for this.

**7. Tim's guessed syntax, `!KAFKA_API_KEY` / "bang".** The real syntax is `secret <name>`:

    properties.sasl.password = secret kafka_api_secret

**8. "If we're going to use the RisingWave secret store, I need to change my process."** He
does not need to build it. `pipelines/shared/000-secrets.rw` plus the `secret.yaml` workflow
already do exactly this, and the file is idempotent (`DROP SECRET IF EXISTS` before each
`CREATE`). What is missing is a confirmed successful run of the workflow, not the mechanism.

**9. The licence is not in the way.** Tim raised "the key Zach gives us". `CREATE SECRET` does
**not** require it — twelve secrets were created on QA while that environment's licence held a
placeholder. The licence gates the console UI and `CdcTableSchemaMap`.

## The clarification that matters most

Tim proposed a **three-way** split: Docker-local, platform, developer. That is an *ownership*
split and it is the right instinct, but it only has one axis. Secret-ness is a **second,
independent** axis, and his own file proves it: `POSTGRES_CDC_PASSWORD` is developer-owned and
secret, `KAFKA_BOOTSTRAP_SERVER` is platform-owned and not secret.

|  | **non-secret** | **secret** |
|---|---|---|
| **platform** | ConfigMap, `endpoints.yaml` — we own the PR | Secrets Manager, we write the value |
| **developer** | ConfigMap, `endpoints.yaml` — Tim owns the PR | Secrets Manager, Tim gives key names, value written once |

Four cells, not three sections. Every key lands in exactly one. This is what to send him.

## Risk to flag back

Tim wants dev, QA **and prod** "as soon as possible", possibly same day. Two reasons that is
not available: `iaac-risingwave-onprem` has no promotion gate, so a merge reaches prod in five
minutes with no approval; and QA Brand is currently mid-flight by design — `kafka_brand` and
both MVs were dropped so the twelve Kafka secrets could be recreated with the corrected
`dx__qa_risingwave` prefix. Dev first, then QA, then prod, one at a time.

Also overlapping: the CDC credentials Tim says "we may have to share" sit next to Idris's
INFRA-1710 PR enabling `wal_level = logical`. That PR targets RisingWave's **meta store**
Postgres (`database: risingwave_meta`), not a CDC source, so the two threads are about
different databases and should not be merged into one conversation.

## Proven

- Both pipelines work end-to-end locally; the blocker is configuration placement, not logic.
- Tim's full `.env` key list is in hand: 75 keys, ten of them new secret material.

## Tested and killed

- "Tim can reuse the External Secrets Operator locally" — ESO has no interface outside
  Kubernetes.
- "The Kafka keys are all config" and "they are all secrets" — both wrong; the section splits.

## Traps

- Two true statements about Octopus vs GitHub, scoped to different repos, sound like a
  contradiction to anyone who joined late.
- "Master is the source of truth" is repo-specific and reads as a general rule.
- Agreeing "absolutely" to a local ESO call costs Tim an afternoon before the mechanism's
  shape makes it impossible.

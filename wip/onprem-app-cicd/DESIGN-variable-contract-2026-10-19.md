# A variable is a contract — making QA fail-proof for a developer
2026-10-19

## The problem, precisely

Tim adds `%NEW_THING%` to a `.rw` file. QA's applier reaches line 181, expands `${!var}`
under `set -u`, and dies: `NEW_THING: unbound variable`. No file name, no key name, nothing
applied, and the Application is wedged until someone forces a sync. The same shape covers a
new pipeline directory and a `LIKE '%ABC%'` wildcard misread as a placeholder.

Worse, the inverse is silent: a variable that EXISTS but is **empty** expands to `''`, the
DDL applies with an empty topic or credential, and `pipeline_applied` records it as a success.

**The root cause is not the applier. It is that a variable has no declaration anywhere.**
Nothing states that `%NEW_THING%` exists, what it means, whether it is secret, or who owns
it. The first system to find out is a sync hook on QA, which is the worst possible place.

## The principle

> **A placeholder is a contract between the developer and the platform. It is declared where
> the need arises — next to the SQL — and the declaration is what the pipeline validates
> against.**

The developer is the only person who knows whether a new value is a Kafka topic name or a
password. So the developer declares it. The platform decides where it is *stored* based on
that declaration, and a human approves before it exists anywhere.

## The flow

| Step | Where | Who | Gate |
|---|---|---|---|
| 1. Add `%NEW_THING%` to SQL | `risingwave-poc` | Tim | — |
| 2. Declare it in `pipelines/config/variables.yaml` with `sensitive: true/false` | `risingwave-poc` | Tim | PR check **fails** if a placeholder has no declaration |
| 3. Check renders every file against each environment's key set | PR in `risingwave-poc` | CI | **fails before merge**, naming the file and the key |
| 4. Platform PR created from the declaration | `risingwave-pipeline` (non-secret) or `iaac-risingwave-onprem` (secret) | bot or us | **PR review — this is the human gate** |
| 5. Secret VALUE supplied | Octopus sensitive variable → `TF_VAR_*` | us | never in Git, never in a PR |
| 6. Promote | `promote.yml` | Tim | the key now exists, so the applier resolves it |

Nothing new is invented for the human gate: **the gate is the platform PR**, which already
requires a code owner. The change is that the PR exists *before* QA breaks rather than after.

### The declaration

```yaml
# pipelines/config/variables.yaml  (in risingwave-poc)
variables:
  KAFKA_TOPIC_EMPLOYEE:
    sensitive: false
    description: Source topic for the Employee CDC pipeline
    environments: [dev, qa]          # where it must exist
  MONGODB_CONNECTION_STRING:
    sensitive: true
    description: Atlas connection string for the brand sink
    environments: [dev, qa, prod]
```

`sensitive` is the only field that changes behaviour. `environments` is what lets a value
legitimately exist on dev and not yet on QA without failing the check — the developer states
the intent instead of the platform guessing.

## What gets built, in dependency order

| # | Thing | Repo | Risk |
|---|---|---|---|
| 1 | **`VALIDATE_ONLY=true`** in `apply.sh` — discover, exclude, substitute, report EVERY missing key with its file, exit. No database, no apply. | `iaac-risingwave-cicd` | additive; nothing opts in |
| 2 | **Reject an empty value** the way an unset one is rejected | `iaac-risingwave-cicd` | behaviour change — see below |
| 3 | **Publish each environment's key NAMES** as a fixture the PR check can read (no values, nothing secret) | `risingwave-pipeline` | new file only |
| 4 | **PR check in `risingwave-poc`** — runs 1 against 3, plus the declaration check | `risingwave-poc` | new workflow |
| 5 | **Idempotency lint** — every `CREATE` is `IF NOT EXISTS`/`OR REPLACE` | same check | lint only |
| 6 | **Declaration → platform PR** automation | `risingwave-pipeline` | last; the manual version works fine meanwhile |

**1 must precede 4** — the check has nothing to run without it. **5 is what makes
`REAPPLY_CHANGED=true` safe**, because today QA will happily re-run a `CREATE SOURCE` that
cannot survive a second run; that is the rename/renumber failure.

### ⚠️ Item 2 inverts the usual rule

Everything else here defaults OFF and is opted into per environment. Making the applier
stricter does the opposite: it can turn a currently-green environment **red** by surfacing a
value that has been empty all along. So it needs a plan for what it finds, not just a flag:

1. Ship `VALIDATE_ONLY` first and run it against dev, QA and prod **read-only**.
2. Fix whatever it names.
3. Only then make empty a hard failure.

Reversing that is how a safety feature becomes an outage.

## The fourth failure: `LIKE '%ABC%'`

The token regex is `%[A-Z][A-Z0-9_]*%` — one character minimum — so a SQL wildcard between
two uppercase words is read as a placeholder. Two options, and the second is better:

- narrow the regex and require two characters: shrinks the window, does not close it
- **require declared placeholders only**: with `variables.yaml` in place, an undeclared token
  is not a placeholder, it is literal text. The declaration removes the ambiguity entirely.

That is the argument for the contract over a cleverer regex: it makes the question decidable
instead of heuristic.

## What this does NOT fix

- A developer writing SQL that is valid on dev and not on QA — different topics, tables or
  ACLs. The digest travels; the world does not. Only dev actually running it catches that.
- A deliberately wrong value. The check proves a key EXISTS, never that it is correct.
- The wedged-Application recovery. That wants `syncPolicy.retry`, which is one field and
  unrelated to this design.

## Proven, and the traps this rests on

- `DRY_RUN=true` already exists but is tested AFTER the Postgres lookup, so it cannot be the
  PR gate — hence item 1 rather than reusing it.
- The shipped `apply.sh` lives in `iaac-risingwave-cicd`, NOT `risingwave-pipeline`. Editing
  the wrong copy cost a day once already ([[edited-copy-is-not-the-shipped-copy]]).
- `EXCLUDE_STRICT` already closes the dead-exclusion-pattern class. Do not rebuild it.

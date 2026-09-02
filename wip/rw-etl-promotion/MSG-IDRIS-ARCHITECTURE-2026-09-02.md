Idris — read through the pipeline architecture doc and the checklist. Short version:
**the architecture is right and I want to build on it.** Build once, promote by digest,
Argo CD reconciles the overlay, ESO resolves credentials, the Job applies from inside the
destination cluster. That is the correct shape, and you have written it down more clearly
than we had it anywhere before.

A few things I specifically want kept, because they are easy to lose later:

- Digest pinning. It is not just tidiness — 515 of the 517 repositories in our shared ECR
  account grant org-wide push and there is no registry policy (INFRA-1655). The digest is
  what makes that safe. Put the reason in the doc or someone will "simplify" it back to a tag.
- The in-cluster Job removing GitHub Actions' network access to the clusters. That is the
  biggest security win in the design and the doc undersells it.
- Refusing `.sql` when the application-database coordinates are missing or resolve to the
  meta store. Exactly the right guard, failing closed on the case that would quietly write
  application tables into the tracking database.
- Rotation step 4 — a running process keeps the old credential. That is live right now on
  op-usxpress-prod: the console will stay broken after the licence lands unless the pod is
  recreated, not just restarted.

Five things to change before we run an environment. None are about the shape — four are the
same pattern, a requirement stated without the mechanism that enforces it.

**1. The Secrets Manager records are Terraform's, and two of them do not exist.**
The checklist reads as a console task. `iaac-risingwave-onprem` Terraform creates those
records and it deploys **through Octopus only**, behind the `TfApply` gate — a hand-made
secret is drift, and `ignore_changes` means Terraform will not correct a wrong value either.
Verified on prod on 1 Sep, it creates five: `root`, `postgres`, `svc-reporting`,
`secret_store_private_key`, `console_license_key`, plus `dex_entra_client_secret` by hand.
**No `entity-postgres`, no `mongodb`.** Adding them is a Terraform change plus a promoted
deploy per environment, which is a bigger ask than the checklist implies.

**2. The doc never mentions Flux — and Flux owns the RisingWave your Job writes into.**
Argo CD owns the pipeline in `app-risingwave`. Flux owns the operator, the CR, the metastore
and the routes in `risingwave`, from `iaac-risingwave-onprem` and `iaac-talos-flux-platform`.
I wired that onto op-usxpress-prod on 1 Sep, with `prune: false` on `risingwave-onprem` so
Flux can create and update in that namespace but never delete. Please add that split near the
diagram — someone following this will go looking for RisingWave in Argo CD, not find it, and
add it, and then two controllers own the same namespace.

**3. "ExternalSecret is Ready" is a proxy, and it failed on prod yesterday.**
You require that a missing or malformed property fail the deployment. Right requirement — but
the ESO status will not give it to you. On 1 Sep `rw-license-key` reported `SecretSynced=True`
within four minutes holding `PLACEHOLDER_INJECT_REAL_LICENSE`; the console rejected it and
that one value also crashlooped `rw-bootstrap-service-accounts`, which has nothing to do with
licensing. Our QA overlay records the sharper case: when a `remoteRef.property` is absent from
the AWS record, ESO still reports Synced and the key is simply missing from the Secret.
Put the control in `apply.sh` — assert every expected variable is present and non-empty before
connecting to anything, exit non-zero naming the ones that are not. Ten lines. Then the
acceptance criterion becomes "the Job fails when a mapped property is absent", which is
testable.

**4. Rollback is undefined, and the design is forward-only.**
The digest is reversible; the database is not. `pipeline_applied` refuses changed files, so
reverting the overlay gives you the old container against a RisingWave that already carries
the new objects. Say plainly that recovery is a new numbered migration, not a rollback — and
then say what happens to the objects the bad file created, because `DROP` is exactly what the
CI guardrail blocks. That tension needs a documented break-glass path with a named approver.

**5. `pipeline_applied` is a single point of replay.**
It lives in the meta PostgreSQL. Restore that from a backup older than the last apply and
every file looks new and runs again against objects that already exist. Not hypothetical —
QA's postgres was reset on 27 Aug, and separately its password drifted from the Secrets
Manager value for eight days because nothing compared them. Prod has the Velero schedule and
no completed backup yet. The doc should state that the tracking table has to be backed up
with, and restored in lockstep with, the objects it describes.

Smaller things:

- **Name the dev namespace.** The contract table is precise for QA and prod and says
  "platform-defined dev namespace" for dev. Dev has zero Argo CD Applications and an empty
  `app-risingwave` today — it is the environment furthest from this design, not a looser
  version of it.
- **`PIPELINE_DIR` vs an exclude list.** You point `PIPELINE_DIR` at `100-Brand`. Our QA
  overlay keeps `PIPELINE_DIR=/pipeline/pipelines` and uses `EXCLUDE_RE` naming each held-back
  directory and why. Both reach the same cutover; the exclude list records the decision in the
  artefact and widens by deleting an exclusion rather than re-pointing a path — which matters
  given your own warning about renames changing tracking keys. Worth converging. Does your
  base have `EXCLUDE_RE`?
- **"A merge to the release branch triggers the build"** needs to assert the digest actually
  changed. On this repo family a commit without a `fix:`/`feat:` prefix produces no version
  bump and no package **and the workflow still goes green** — that is why release 0.5.3 picked
  up an August package.
- **The Kafka secret will bite the first real cutover.** On 26 Aug
  `op-usxpress-qa/risingwave/kafka` held 6 of dev's 9 keys. Brand's source is
  `FORMAT PLAIN ENCODE AVRO`, so without the three `KAFKA__schema_registry_*` values it cannot
  decode a message — and per point 3, ESO will report Synced with them missing. Worth naming
  them explicitly in the ExternalSecret section.

One correction on framing, since it caught me out recently too: the doc treats the platform
prerequisites as things someone else provides. Check whether a sibling environment already
solved it first. The prod Entra "app registration request" evaporated once dev and QA turned
out to share one registration — prod was a redirect URI and a copied secret, done in a minute.

Nothing here blocks you starting on points 1 and 3, which are the two that gate a real run.

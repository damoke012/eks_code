# Review — RisingWave Pipeline Architecture + Implementation Checklist (Idris)

**Date:** 2026-09-02 · **Reviewer:** Dare Oke · **Type:** design review, not a PR
**Repo:** `variant-inc/risingwave-pipeline` · **Targets:** op-usxpress-dev / -qa / -prod

## Verdict

**The architecture is right and I would build on it.** Build once, promote by digest,
reconcile with Argo CD, resolve credentials through ESO, apply from inside the destination
cluster. That is the correct shape and the document states it more clearly than anything we
have written down so far.

Five things must change before an environment run, and none of them are about the shape.
Four are omissions where the document states a requirement without naming the mechanism that
enforces it — which is how a requirement becomes an aspiration.

---

## Cleared — keep these exactly as written

- **Build once, promote by digest, never rebuild for production.** Correct, and it is the
  only thing that makes our shared ECR safe: 515 of 517 repositories in account
  `064859874041` grant org-wide push and there is no registry policy (INFRA-1655). Put that
  reason in the document, or someone will "simplify" it back to a mutable tag later.
- **In-cluster apply Job as an Argo Sync hook.** Right for the stated reason (RisingWave is
  ClusterIP) and for a better one the document should claim explicitly: it removes GitHub
  Actions' network access to the clusters entirely. That is the single biggest security win
  in the design.
- **Non-root UID 10001, no credentials in the image, no environment baked in.** Correct.
- **"Do not select an AWS account, cluster, or secret path from untrusted pipeline input"**
  and "do not select an AWS account from a branch name inside the container." Correct, and
  worth the repetition.
- **Refusing `.sql` when application-database coordinates are missing, or resolve to the
  pipeline's own meta store.** This is the guard we specified on 2026-08-31 and it is the
  right one — it fails closed on the case that would silently write application tables into
  the tracking database.
- **Secret rotation step 4** — "a running process may retain the old credential." Correct and
  frequently missed. It is why the console on op-usxpress-prod would stay broken today even
  after the licence lands, unless the pod is recreated rather than the container restarted.
- **CI guardrail on unguarded drops, tested in both directions.** Testing that guarded drops
  and `GRANT DROP` still pass is the half people skip, and it is the half that catches a
  guard which blocks everything.
- **Retiring `.github/workflows/pipeline.yaml`.** It holds a hardcoded dev AWS role and reads
  secrets in GitHub Actions. Agreed, and the transitional wording is honest.

---

## Must change

### 1. BLOCKER — the secret records are Terraform's, and three of them do not exist

The checklist lists five records per environment as "External Platform Prerequisites":

    op-usxpress-{env}/risingwave/{root,postgres,entity-postgres,kafka,mongodb}

Two problems.

**(a) Terraform owns these, not the console.** `iaac-risingwave-onprem/deploy/terraform`
creates the RisingWave Secrets Manager records, and it is deployed **through Octopus only**
with a `TfApply` gate. A record created by hand is drift; the next apply may not keep it, and
`ignore_changes` on the ones that have it means Terraform will not correct a wrong value
either. "Create and validate" is a Terraform change plus a promoted deploy per environment,
not a console action. The document should say so, because the way it reads now is exactly how
we end up with five hand-made secrets that nothing reproduces.

**(b) Verified on op-usxpress-prod 2026-09-01, Terraform creates five:** `root`, `postgres`,
`svc-reporting`, `secret_store_private_key`, `console_license_key`, plus
`dex_entra_client_secret` created by hand. **`entity-postgres` is not among them, and neither
is `mongodb`.** `kafka` exists in QA (with a known gap, see advisory 4) — its existence in
prod is unverified.

Confirm before planning around it:

```bash
for s in entity-postgres kafka mongodb; do
  printf '%-16s ' "$s"
  aws secretsmanager describe-secret --secret-id "op-usxpress-prod/risingwave/$s" \
    --profile ops-controller --region us-east-2 --query Name --output text 2>&1 | tail -1
done
```

`--region` matters: without it Secrets Manager answers `ResourceNotFoundException` from
whatever region the profile defaults to, which reads identically to "absent". That cost us an
hour on 2026-09-01.

**Ask:** state that AWS Secrets Manager records are provisioned by
`iaac-risingwave-onprem` Terraform via Octopus, and list which records exist today versus
which the pipeline still needs.

### 2. BLOCKER — the document never mentions Flux, and the boundary is load-bearing

The architecture diagram shows Argo CD reconciling everything. It does not. On every on-prem
cluster:

| Layer | Controller | Repo | Namespace |
|---|---|---|---|
| RisingWave itself (operator, CR, metastore, routes) | **Flux** | `iaac-risingwave-onprem` + `iaac-talos-flux-platform` | `risingwave` |
| The ETL pipeline (Job, ConfigMap, ExternalSecret) | **Argo CD** | `risingwave-pipeline` | `app-risingwave` |

Wired on op-usxpress-prod on 2026-09-01: Flux Kustomizations `risingwave-operator`,
`risingwave-onprem` and `risingwave-routes`, with **`prune: false`** on `risingwave-onprem` —
Flux may create and update in `risingwave` but can never delete there. That guard is what
protects the objects the apply Job writes into.

A reader following this document would look for the RisingWave deployment in Argo CD and not
find it. Worse, someone might add it, and then two controllers own the same namespace.

**Ask:** add the table above near the architecture diagram, and state that the Job reaches
*across* namespaces to `risingwave-frontend.risingwave.svc.cluster.local`.

### 3. BLOCKER — "ExternalSecret is Ready" is a proxy, and it failed on prod yesterday

The document requires: *"A missing or malformed property must make the deployment fail rather
than create an incomplete credential set."* Correct requirement. **No mechanism is given, and
the ESO status will not provide one.**

Evidence from 2026-09-01, op-usxpress-prod: `rw-license-key` reported `SecretSynced=True`
within four minutes, holding `PLACEHOLDER_INJECT_REAL_LICENSE`. The console rejected it, and
that one bad value also crashlooped `rw-bootstrap-service-accounts`, a Job with nothing to do
with licensing. A green ExternalSecret proves the sync ran. It says nothing about content.

Our own QA overlay records the sharper version: when a `remoteRef.property` is absent from the
AWS record, **ESO still reports `SecretSynced` and the key is simply missing** from the
Kubernetes Secret.

The control belongs in `apply.sh`, before it connects to anything: assert every expected
variable is present and non-empty, and exit non-zero naming the ones that are not. Ten lines,
and it converts a silent partial credential set into a failed Job.

**Ask:** move the requirement out of Acceptance Criteria and into the container, then keep
the acceptance criterion — but word it as "the Job fails when a mapped property is absent",
which is testable, rather than "ExternalSecret is Ready", which is not.

### 4. BLOCKER — rollback is undefined, and the design is forward-only

Promotion by digest is reversible for the *container*. It is not reversible for the *database*.
`pipeline_applied` records each file's SHA-256, skips unchanged files and refuses changed
ones. So after a bad production apply, reverting the overlay to the previous digest gives you
the old container pointed at a RisingWave that already carries the new objects.

The document says a failed production deployment "must be investigated at the overlay, secret,
network, or SQL level" — true, but it never says what recovery *is*.

**Ask:** state plainly that the pipeline is forward-only. Recovery from a bad apply is a new
numbered migration file, not a digest rollback. Then say what to do about the RisingWave
objects the bad file created, because `DROP` is exactly what the CI guardrail blocks — that
tension needs a documented break-glass path with a named approver.

### 5. BLOCKER — the tracking table is a single point of replay

`pipeline_applied` lives in the meta PostgreSQL (`pg-postgresql` in the `risingwave`
namespace). If that database is reset, or restored from a backup older than the last apply,
every file looks new and runs again — against a RisingWave that already has the objects.

This is not hypothetical: QA's postgres was reset on 2026-08-27, and separately its password
drifted from the Secrets Manager value for eight days before anyone noticed, because nothing
compared them.

On op-usxpress-prod today there is a Velero `Schedule` named `risingwave-metastore` and **no
completed backup yet**.

**Ask:** state that `pipeline_applied` must be backed up with, and restored in lockstep with,
the RisingWave objects it describes — and that a metastore restore requires reconciling the
tracking table before the next sync, or the first Argo sync after a restore replays history.

---

## Advisory

1. **Name the dev namespace.** The contract table is precise for QA and prod
   (`app-risingwave`) and says "platform-defined dev namespace" for dev. Dev is the
   environment that most needs pinning: it currently has **zero Argo CD Applications and an
   empty `app-risingwave`**, and still runs the legacy direct-execution workflow. Dev is not a
   less-formal version of the design; it is the environment furthest from it.

2. **`PIPELINE_DIR` versus an exclude list.** The checklist says set
   `PIPELINE_DIR=/pipeline/pipelines/100-Brand`. Our QA overlay instead sets
   `PIPELINE_DIR=/pipeline/pipelines` with an `EXCLUDE_RE` naming each held-back directory and
   why (`Template`, `scripts`, `900-user-access`, `employee`, `secret_manager`,
   `001-secrets-mongodb`, `400-sink`). Both reach the same first cutover. The exclude list
   records the decision in the artefact and widens by deleting an exclusion rather than
   re-pointing a path — which matters, because the document's own warning about directory
   renames changing tracking-table keys applies to re-pointing too. Converge on one; the
   document does not mention `EXCLUDE_RE`, so confirm it exists in the base.

3. **"A merge to the release branch triggers the build" needs a verified digest, not a green
   workflow.** On this repo family a commit without a `fix:`/`feat:` prefix produces no
   version bump and no package, **and the workflow still succeeds** — that is exactly why
   release `0.5.3` selected an August package. Make the promotion PR assert that the digest it
   writes is the digest that build produced, and fail if no new image was pushed.

4. **The Kafka secret was incomplete in QA and it will bite the first real cutover.** On
   2026-08-26 `op-usxpress-qa/risingwave/kafka` held 6 of dev's 9 keys. Brand's source is
   `FORMAT PLAIN ENCODE AVRO`, so without
   `KAFKA__schema_registry_{api_key,api_secret,endpoint}` it cannot decode a message — and per
   finding 3, ESO will report `SecretSynced` with those keys simply absent. Carry that concrete
   list into the ExternalSecret section rather than "add mappings for connector credentials
   required by the selected pipeline".

5. **State why digest pinning exists.** See Cleared, item 1. A rule without its reason gets
   optimised away.

---

## Proven

- The delivery path itself is proven: GHA → ECR → Argo CD reached op-usxpress-qa on
  2026-08-20 and ran the Job — carrying a **smoke** payload, which the document correctly
  identifies as scaffolding rather than a cutover.
- RisingWave is running on op-usxpress-prod as of 2026-09-01: `RUNNING=True`, v2.8.2,
  PostgreSQL metastore and S3 state store bound. The target the pipeline needs exists.
- Prod's six Secrets Manager records, the IRSA role `op-usxpress-prod-risingwave` and the
  bucket `risingwave-state-op-usxpress-prod` all exist and were read back on 2026-09-01.

## Tested and killed

- **"The prod Entra app registration is a multi-day identity request."** It was not — dev, QA
  and prod share registration `e112d6ce-cc60-4884-9898-8fcc5b78b0b1` and prod needed only a
  redirect URI, added 2026-09-01. Mentioned here because the document's "external
  prerequisites" framing invites the same error: check whether a sibling environment already
  solved it before raising a request.

## Traps

- **A green ExternalSecret is not a valid value** (finding 3). Third occurrence.
- **`describe-secret` without `--region` reports a real secret as absent** — a true
  `ResourceNotFoundException` about the wrong region.
- **Argo CD Applications for these overlays do not exist on dev or prod.** The document lists
  them as external prerequisites, which is accurate, but they are open tickets (INFRA-1636
  ApplicationSet for op-usxpress-prod, INFRA-1650 Argo CD Git credential on prod) — not
  paperwork. QA is the only environment where this path has ever run.
